import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../api/key_value_store.dart';
import '../../data/local_database.dart';
import '../../data/table.dart';
import 'backup_crypto.dart';
import 'backup_keys.dart';

/// 导入失败的分类（页面按此给友好提示 / 决定是否弹密码框重试）。
enum BackupFailureKind {
  /// 不是本应用的备份文件（magic 不匹配 / 结构不对）。
  invalidFile,

  /// 备份文件版本比当前应用新。
  tooNew,

  /// 加密备份但未提供密码。
  needsPassword,

  /// 密码错误 / 文件被篡改 / 密文损坏（统一口径，防枚举）。
  wrongPassword,

  /// 白名单内数据损坏（如某张表行结构非法）。
  corrupt,
}

class BackupFailure implements Exception {
  const BackupFailure(this.kind, this.message);

  final BackupFailureKind kind;
  final String message;

  @override
  String toString() => message;
}

/// 确认框里的一条「将被覆盖的数据」。
class ImportEntry {
  const ImportEntry({required this.key, required this.label, required this.detail});

  final String key;
  final String label;
  final String detail;
}

/// 已在内存完成「解析 → 校验 → 转换」的待导入数据（fail-safe：
/// [BackupService.applyImport] 之前绝不触碰本地数据）。
class StagedImport {
  const StagedImport({
    required this.createdAt,
    required this.appVersion,
    required this.encrypted,
    required this.entries,
    required this.kvWrites,
    required this.tableRows,
  });

  final DateTime? createdAt;
  final String appVersion;
  final bool encrypted;

  /// 确认框条目（中文 label + 概览）。
  final List<ImportEntry> entries;

  /// 待写入的 KV（设置 + 敏感字段），值已转字符串。
  final Map<String, String> kvWrites;

  /// 待整体替换的表：表名 → 已解码行。
  final Map<String, List<Map<String, dynamic>>> tableRows;
}

/// 数据备份 / 还原（本地文件，替代原 WebDAV 云同步）。
///
/// - **白名单制**：只读写 [BackupWhitelist] 声明的 key；
/// - **前向兼容**：导入忽略不认识的 key、跳过 null；只覆盖文件中实际
///   存在的项，本机其余白名单数据不动；
/// - **fail-safe**：解析与校验全程内存操作，[applyImport] 一次性写回；
/// - 文件结构见 README：顶层 magic + formatVersion + payload（或加密结构）。
class BackupService extends ChangeNotifier {
  BackupService({
    required this.kv,
    required this.db,
    this.appVersionProvider,
    this.afterRestore,
  });

  static const String magic = 'kele-audio-backup';
  static const int formatVersion = 1;

  final KeyValueStore kv;
  final LocalDatabase db;

  /// 备份文件 appVersion 字段的来源（package_info）。
  final Future<String> Function()? appVersionProvider;

  /// 导入落盘后的刷新钩子（DI 装配：重载主题/书架/播放参数/登录态等内存缓存，
  /// 让还原「即时生效」，重启只是兜底）。
  final Future<void> Function()? afterRestore;

  bool _busy = false;

  /// 是否正在导出/解析/写回（页面禁用按钮防连点）。
  bool get busy => _busy;

  // ---------------------------------------------------------------- 导出

  /// 生成备份文件字节。[password] 非空则 AES-256-CBC + HMAC 加密。
  Future<Uint8List> buildBackup({String? password}) async {
    return _guard(() async {
      await db.ensureCreated();
      final payload = <String, dynamic>{};

      // 白名单设置 KV（本机没有的 key 不写，导入端也只认文件里有的）
      final keys = <String, dynamic>{};
      for (final item in BackupWhitelist.settingsItems) {
        final v = kv.getString(item.key);
        if (v != null) keys[item.key] = v;
      }
      for (final table in BackupWhitelist.tablesOf(db)) {
        final storageKey = Table.storageKey(table.name);
        keys[storageKey] = _encodeTable(table);
      }
      payload['keys'] = keys;

      // 敏感字段（登录态）
      final secure = <String, dynamic>{};
      for (final item in BackupWhitelist.secureItems) {
        final v = kv.getString(item.key);
        if (v != null && v.isNotEmpty) secure[item.key] = v;
      }
      payload['secure'] = secure;

      final envelope = <String, dynamic>{
        'magic': magic,
        'formatVersion': formatVersion,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'appVersion': await appVersionProvider?.call() ?? '',
        'encrypted': false,
      };

      if (password == null || password.isEmpty) {
        envelope['payload'] = payload;
      } else {
        envelope['encrypted'] = true;
        envelope['payload'] = encryptBackupPayload(payload, password);
      }
      return Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
    });
  }

  // ---------------------------------------------------------------- 导入

  /// 解析 + 校验备份文件（**不写任何本地数据**）。
  ///
  /// 加密文件缺密码抛 [BackupFailureKind.needsPassword]；密码错误抛
  /// [BackupFailureKind.wrongPassword]（页面弹密码框重试）。
  Future<StagedImport> parseImport(Uint8List bytes, {String? password}) {
    return _guard(() async {
      final Map<String, dynamic> envelope;
      try {
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is! Map<String, dynamic>) throw const FormatException();
        envelope = decoded;
      } catch (_) {
        throw const BackupFailure(
          BackupFailureKind.invalidFile,
          '无法解析该文件，请确认选择的是本应用导出的备份文件',
        );
      }

      if (envelope['magic'] != magic) {
        throw const BackupFailure(
          BackupFailureKind.invalidFile,
          '这不是本应用的备份文件',
        );
      }
      final version = (envelope['formatVersion'] as num?)?.toInt();
      if (version == null || version < 1) {
        throw const BackupFailure(
          BackupFailureKind.invalidFile,
          '备份文件版本异常，无法导入',
        );
      }
      if (version > formatVersion) {
        throw const BackupFailure(
          BackupFailureKind.tooNew,
          '该备份由更新版本的应用导出，请先升级应用再导入',
        );
      }

      // payload：明文对象 或 加密结构
      final rawPayload = envelope['payload'];
      if (rawPayload is! Map<String, dynamic>) {
        throw const BackupFailure(
          BackupFailureKind.invalidFile,
          '备份文件数据缺失或已损坏',
        );
      }
      final isEncrypted = envelope['encrypted'] == true ||
          rawPayload.containsKey('ciphertext');
      Map<String, dynamic> payload;
      if (isEncrypted) {
        final pw = password;
        if (pw == null || pw.isEmpty) {
          throw const BackupFailure(
            BackupFailureKind.needsPassword,
            '该备份文件已加密，请输入导出时设置的密码',
          );
        }
        try {
          payload = decryptBackupPayload(rawPayload, pw);
        } on BackupCryptoException {
          throw const BackupFailure(
            BackupFailureKind.wrongPassword,
            '密码错误或文件已损坏',
          );
        }
      } else {
        payload = rawPayload;
      }

      return _stagePayload(envelope, payload, isEncrypted);
    });
  }

  /// 确认覆盖后一次性整批写回（KV + 三表整体替换），随后触发
  /// [afterRestore] 重载内存态。
  Future<void> applyImport(StagedImport staged) async {
    await _guard(() async {
      for (final e in staged.kvWrites.entries) {
        await kv.setString(e.key, e.value);
      }
      final tables = {for (final t in BackupWhitelist.tablesOf(db)) t.name: t};
      for (final e in staged.tableRows.entries) {
        final table = tables[e.key];
        if (table == null) continue;
        await table.replaceAllDecoded(e.value);
      }
      await afterRestore?.call();
    });
  }

  // ---------------------------------------------------------------- 内部

  /// payload → StagedImport：白名单过滤 + 行解码（全部成功才返回）。
  StagedImport _stagePayload(
    Map<String, dynamic> envelope,
    Map<String, dynamic> payload,
    bool encrypted,
  ) {
    final rawKeys = payload['keys'];
    final rawSecure = payload['secure'];
    if (rawKeys != null && rawKeys is! Map) {
      throw const BackupFailure(
        BackupFailureKind.corrupt,
        '备份文件数据结构异常，无法导入',
      );
    }
    if (rawSecure != null && rawSecure is! Map) {
      throw const BackupFailure(
        BackupFailureKind.corrupt,
        '备份文件数据结构异常，无法导入',
      );
    }

    final keys = rawKeys == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(rawKeys as Map);
    final secure = rawSecure == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(rawSecure as Map);

    final kvWrites = <String, String>{};
    final entries = <ImportEntry>[];

    // 设置 KV：未知 key 忽略、null 跳过（前向兼容）
    for (final item in BackupWhitelist.settingsItems) {
      final v = keys[item.key];
      if (v == null) continue;
      kvWrites[item.key] = '$v';
      entries.add(ImportEntry(key: item.key, label: item.label, detail: '设置项'));
    }

    // 表：key 必须在白名单表集合内（文件按 `t_*` 存储），行结构逐条解码
    //（任一失败整体拒绝）
    final tablesByStorageKey = {
      for (final t in BackupWhitelist.tablesOf(db)) Table.storageKey(t.name): t,
    };
    final tableRows = <String, List<Map<String, dynamic>>>{};
    for (final entry in keys.entries) {
      final table = tablesByStorageKey[entry.key];
      if (table == null) continue; // 不认识的 key 忽略
      final tableName = table.name;
      final value = entry.value;
      if (value == null) continue; // null 跳过
      if (value is! List) {
        throw const BackupFailure(
          BackupFailureKind.corrupt,
          '备份数据格式异常，无法导入',
        );
      }
      List<Map<String, dynamic>> rows;
      try {
        rows = value
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList();
        // 试解码一遍：行结构非法在这里整体拒绝，绝不半覆盖
        for (final r in rows) {
          table.decode(r);
        }
      } catch (_) {
        throw const BackupFailure(
          BackupFailureKind.corrupt,
          '备份数据已损坏（表行结构非法），无法导入',
        );
      }
      tableRows[tableName] = rows;
      entries.add(ImportEntry(
        key: entry.key,
        label: BackupWhitelist.tableLabels[tableName] ?? tableName,
        detail: '${rows.length} 条',
      ));
    }

    // 敏感字段
    for (final item in BackupWhitelist.secureItems) {
      final v = secure[item.key];
      if (v == null) continue;
      kvWrites[item.key] = '$v';
      entries.add(ImportEntry(key: item.key, label: item.label, detail: '登录态'));
    }

    return StagedImport(
      createdAt: _tryParseDate(envelope['createdAt'] as String?),
      appVersion: '${envelope['appVersion'] ?? ''}',
      encrypted: encrypted,
      entries: entries,
      kvWrites: kvWrites,
      tableRows: tableRows,
    );
  }

  static DateTime? _tryParseDate(String? iso) {
    if (iso == null || iso.isEmpty) return null;
    return DateTime.tryParse(iso)?.toLocal();
  }

  /// 表编码走 [Table.encodeAll]（`T` 在 `encode` 参数位，经
  /// `Table<dynamic>` 撕裂字段会触发运行时签名检查失败）。
  static List<Map<String, dynamic>> _encodeTable(Table<dynamic> t) =>
      t.encodeAll();

  Future<T> _guard<T>(Future<T> Function() body) async {
    if (_busy) {
      throw const BackupFailure(
        BackupFailureKind.invalidFile,
        '正在处理上一个备份操作，请稍候',
      );
    }
    _busy = true;
    notifyListeners();
    try {
      return await body();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
