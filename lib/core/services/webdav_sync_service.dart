import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../api/key_value_store.dart';
import '../api/webdav_client.dart';
import '../data/local_database.dart';
import '../data/table.dart';
import '../domain/records.dart';
import 'offline/offline_cache_service.dart';
import 'player/progress_store.dart';
import 'settings_store.dart';

/// 一次备份/同步的结果（页面 SnackBar 展示）。
class WebdavSyncResult {
  const WebdavSyncResult.ok(this.message) : ok = true;

  const WebdavSyncResult.fail(this.message) : ok = false;

  final bool ok;
  final String message;
}

/// WebDAV 云同步（M5 账号绑定）：手动「备份到云端 / 从云端同步」。
///
/// 设计定案（2026-10-28 用户确认）：
/// - **整体覆盖、无合并**：备份 = 本机 → 云端覆盖；同步 = 云端 → 本机覆盖，
///   多设备使用时后操作者胜；两步执行前由页面弹二次确认；
/// - **同步集**：设置 KV + shelf + play_history + play_log 四件套；
///   不同步缓存（album/chapter/发现页）、离线下载文件与 B 站登录态；
/// - **云端布局**：可配置目录（默认 `kele-audio/`）下 4 个 JSON——
///   `settings.json`（KV 映射）+ 三个表文件（与本地 `t_*` 同构的 JSON 数组）；
/// - **凭据**明文存本机 KV（个人工具），页面提示 HTTPS + 应用专用密码；
///   解绑只清本地凭据，不删云端文件。
class WebdavSyncService extends ChangeNotifier {
  WebdavSyncService({
    required this.kv,
    required this.db,
    CloudStore Function(String url, String username, String password)?
        clientFactory,
    this.afterRestore,
  }) : _clientFactory = clientFactory ?? _defaultFactory;

  static const String keyUrl = 'webdav_url';
  static const String keyUsername = 'webdav_username';
  static const String keyPassword = 'webdav_password';
  static const String keyDir = 'webdav_dir';
  static const String defaultDir = 'kele-audio';

  /// 同步的设置 KV key（owner：SettingsStore / PlayerPrefs /
  /// ThemeController（app 层，按层不反向引用，key 在此字面量固化）/
  /// OfflineCacheService）。`theme_mode` 是旧迁移键，不同步。
  static const List<String> settingsKeys = [
    SettingsStore.keyWifiOnly,
    SettingsStore.keyFeaturedVisible,
    SettingsStore.keyHiddenCategories,
    PlayerPrefs.keyRate,
    PlayerPrefs.keyMode,
    PlayerPrefs.keyQuality,
    PlayerPrefs.keyStopAtChapterEnd,
    PlayerPrefs.keyAutoNext,
    OfflineCacheService.keyOnlyCached,
    'theme_preset', // ThemeController.presetKey
    'children_mode', // ThemeController.childrenKey
  ];

  /// 同步的表文件（与 [Table.storageKey] 同构）。
  static const List<String> tableFiles = [
    'shelf.json',
    'play_history.json',
    'play_log.json',
  ];

  static const String settingsFile = 'settings.json';

  final KeyValueStore kv;
  final LocalDatabase db;
  final CloudStore Function(String url, String username, String password)
      _clientFactory;

  /// 同步落库后的刷新钩子（DI 装配：重载主题/书架/播放参数等内存缓存）。
  final Future<void> Function()? afterRestore;

  bool _busy = false;

  /// 是否正在备份/同步（页面禁用按钮）。
  bool get busy => _busy;

  String? get serverUrl {
    final v = (kv.getString(keyUrl) ?? '').trim();
    return v.isEmpty ? null : v;
  }

  String get username => kv.getString(keyUsername) ?? '';

  String get dir {
    final v = (kv.getString(keyDir) ?? '').trim();
    return v.isEmpty ? defaultDir : v;
  }

  /// 是否已绑定（有服务器地址即视为绑定）。
  bool get bound => serverUrl != null;

  static CloudStore _defaultFactory(
    String url,
    String username,
    String password,
  ) =>
      WebdavClient(baseUrl: url, username: username, password: password);

  CloudStore _store(String url, String username, String password) =>
      _clientFactory(url.trim(), username, password);

  /// 测试连接（不保存凭据）。
  Future<WebdavSyncResult> testConnection({
    required String url,
    required String username,
    required String password,
  }) async {
    try {
      await _store(url, username, password).testConnection();
      return const WebdavSyncResult.ok('连接成功');
    } on WebdavException catch (e) {
      return WebdavSyncResult.fail(e.message);
    } catch (e) {
      return WebdavSyncResult.fail('连接失败：$e');
    }
  }

  /// 绑定 = 保存凭据（建议先 [testConnection]）。
  Future<WebdavSyncResult> bind({
    required String url,
    required String username,
    required String password,
    String? dir,
  }) async {
    final u = url.trim();
    if (u.isEmpty || username.trim().isEmpty) {
      return const WebdavSyncResult.fail('请填写服务器地址与用户名');
    }
    await kv.setString(keyUrl, u);
    await kv.setString(keyUsername, username.trim());
    await kv.setString(keyPassword, password);
    final d = (dir ?? '').trim();
    if (d.isEmpty) {
      await kv.remove(keyDir);
    } else {
      await kv.setString(keyDir, d);
    }
    notifyListeners();
    return const WebdavSyncResult.ok('绑定成功');
  }

  /// 解绑：只清本地凭据（云端文件保留）。
  Future<WebdavSyncResult> unbind() async {
    for (final k in const [keyUrl, keyUsername, keyPassword, keyDir]) {
      await kv.remove(k);
    }
    notifyListeners();
    return const WebdavSyncResult.ok('已解除绑定，云端备份文件保留');
  }

  /// 备份到云端：本地四件套整体上传覆盖。
  Future<WebdavSyncResult> backup() async {
    final creds = _requireCreds();
    if (creds == null) return const WebdavSyncResult.fail('尚未绑定 WebDAV');
    return _guard(() async {
      await db.ensureCreated();
      final payloads = _buildPayloads();
      final store = _store(creds.$1, creds.$2, creds.$3);
      await store.ensureDir(dir);
      for (final entry in payloads.entries) {
        await store.putFile('$dir/${entry.key}', entry.value);
      }
      return WebdavSyncResult.ok('已备份到云端（${payloads.length} 个文件）');
    });
  }

  /// 从云端同步：云端四件套整体下载覆盖本机（无合并）。
  ///
  /// 两阶段：先取齐并解析全部文件（任一失败即中止、本机不动），再落库。
  Future<WebdavSyncResult> syncFromCloud() async {
    final creds = _requireCreds();
    if (creds == null) return const WebdavSyncResult.fail('尚未绑定 WebDAV');
    return _guard(() async {
      await db.ensureCreated();
      final store = _store(creds.$1, creds.$2, creds.$3);
      final files = [settingsFile, ...tableFiles];
      final raw = <String, String>{};
      for (final f in files) {
        final s = await store.getFile('$dir/$f');
        if (s == null) {
          return WebdavSyncResult.fail(
            '云端备份不完整（缺 $f），请先在其他设备「备份到云端」',
          );
        }
        raw[f] = s;
      }

      // 解析（全部成功才落库，防半覆盖）
      late final Map<String, dynamic> settings;
      late final List<ShelfItem> shelfRows;
      late final List<PlayHistory> historyRows;
      late final List<PlayLogEntry> logRows;
      try {
        final m = jsonDecode(raw[settingsFile]!);
        if (m is! Map) throw const FormatException('settings.json 不是对象');
        settings = Map<String, dynamic>.from(m);
        shelfRows = _parseRows(db.shelf, _asList(raw['shelf.json']!));
        historyRows = _parseRows(db.playHistory, _asList(raw['play_history.json']!));
        logRows = _parseRows(db.playLogs, _asList(raw['play_log.json']!));
      } catch (e) {
        return WebdavSyncResult.fail('云端数据格式异常：$e');
      }

      // 应用：设置 KV（云端缺 key = 恢复默认值）+ 三表整体替换
      for (final k in settingsKeys) {
        final v = settings[k];
        if (v == null) {
          await kv.remove(k);
        } else {
          await kv.setString(k, '$v');
        }
      }
      await db.shelf.replaceAll(shelfRows);
      await db.playHistory.replaceAll(historyRows);
      await db.playLogs.replaceAll(logRows);
      await afterRestore?.call();
      return const WebdavSyncResult.ok('同步完成，已覆盖本机数据');
    });
  }

  // ---------------------------------------------------------------- 内部

  (String, String, String)? _requireCreds() {
    final url = serverUrl;
    if (url == null) return null;
    return (url, username, kv.getString(keyPassword) ?? '');
  }

  Future<WebdavSyncResult> _guard(
    Future<WebdavSyncResult> Function() body,
  ) async {
    if (_busy) return const WebdavSyncResult.fail('正在同步，请稍候');
    _busy = true;
    notifyListeners();
    try {
      return await body();
    } on WebdavException catch (e) {
      return WebdavSyncResult.fail(e.message);
    } catch (e) {
      return WebdavSyncResult.fail('操作失败：$e');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Map<String, String> _buildPayloads() {
    final settings = <String, String>{};
    for (final k in settingsKeys) {
      final v = kv.getString(k);
      if (v != null) settings[k] = v;
    }
    String tableJson<T>(Table<T> t) =>
        jsonEncode(t.all().map(t.encode).toList());
    return {
      settingsFile: jsonEncode(settings),
      'shelf.json': tableJson(db.shelf),
      'play_history.json': tableJson(db.playHistory),
      'play_log.json': tableJson(db.playLogs),
    };
  }

  static List<dynamic> _asList(String raw) {
    final v = jsonDecode(raw);
    if (v is! List) throw const FormatException('表文件不是数组');
    return v;
  }

  static List<T> _parseRows<T>(Table<T> t, List<dynamic> list) => list
      .map((e) => t.decode(Map<String, dynamic>.from(e as Map)))
      .toList();
}
