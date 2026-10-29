import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/api/api_config.dart';
import '../core/api/album_source.dart';
import '../core/api/bili_client.dart';
import '../core/api/content_config.dart';
import '../core/api/discover_source.dart';
import '../core/api/key_value_store.dart';
import '../core/api/play_url_service.dart';
import '../core/api/prefs_kv_store.dart';
import '../core/data/daos.dart';
import '../core/data/discover_cache.dart';
import '../core/data/local_database.dart';
import '../core/services/bili_account_service.dart';
import '../core/services/mini_player_controller.dart';
import '../core/services/offline/dio_audio_fetcher.dart';
import '../core/services/offline/audio_store.dart';
import '../core/services/offline/offline_cache_service.dart';
import '../core/services/player/media_bridge.dart';
import '../core/services/player/player_service.dart';
import '../core/services/player/progress_store.dart';
import '../core/services/settings_store.dart';
import '../core/services/shelf_controller.dart';
import '../core/services/webdav_sync_service.dart';
import 'theme/theme_controller.dart';

/// 应用级服务集合（DI）：一次性启动装配，页面用 `context.read` 取用。
class AppServices {
  AppServices._({
    required this.kv,
    required this.config,
    required this.content,
    required this.childrenContent,
    required this.client,
    required this.db,
    required this.daos,
    required this.theme,
    required this.miniPlayer,
    required this.playUrl,
    required this.albums,
    required this.discover,
    required this.discoverCache,
    required this.progress,
    required this.prefs,
    required this.player,
    required this.shelf,
    required this.settings,
    required this.offline,
    required this.account,
    required this.webdav,
  });

  final KeyValueStore kv;
  final ApiConfig config;

  /// 内容源配置（M3：分类 / 查询 / 黑名单，R1 式远端热修复）
  final ContentConfig content;

  /// 儿童白名单配置（M6 / PRD §7.3）：内置默认 + 远端覆盖，独立缓存 key
  final ContentConfig childrenContent;
  final BiliClient client;
  final LocalDatabase db;
  final Daos daos;
  final ThemeController theme;
  final MiniPlayerController miniPlayer;

  /// 播放地址服务（DASH 取址 + 内存缓存，**地址不落库**）
  final PlayUrlService playUrl;

  /// 章节来源（多 P / 合集系列）
  final AlbumSource albums;

  /// 发现页聚合源（合集/UP 优先 + 搜索补充 + 过滤去重）
  final DiscoverSource discover;

  /// 分类首页缓存（TTL 由内容配置下发）
  final DiscoverPageCache discoverCache;

  /// 播放进度持久化（P-03 / P-04）
  final ProgressStore progress;

  /// 播放参数持久化（P-08：倍速 / 音质 / 模式）
  final PlayerPrefs prefs;

  /// 播放核心（M2）：专辑 → 章节 → 取址 → 播放 → 落进度
  final PlayerService player;

  /// 书架（M4）：收藏状态的单一事实源 + shelf×album×play_history 联合查询
  final ShelfController shelf;

  /// 设置页持久化（M5）：仅 Wi-Fi 下载占位开关等
  final SettingsStore settings;

  /// 离线缓存（M8）：整本缓存队列 + 缓存播放联动
  final OfflineCacheService offline;

  /// B 站账号绑定（M5）：扫码登录状态机 + 绑定态/账号档案
  final BiliAccountService account;

  /// WebDAV 云同步（M5 账号绑定）：手动备份/同步四件套（整体覆盖）
  final WebdavSyncService webdav;

  /// 启动装配：**不发任何网络请求**（PRD 冷启动 ≤ 3s）。
  ///
  /// 顺序：本地 KV → 接口配置（内置 JSON，R1 远端覆盖失败静默）→
  /// Dio 本地初始化 → 建表 → 主题读取 → 播放核心装配（零引擎、零网络）。
  ///
  /// [mediaBridge] 由 `main.dart` 在移动端注入（audio_service）；
  /// Web / 初始化失败时为 [NoopMediaBridge]，播放照常。
  static Future<AppServices> bootstrap({
    bool? isWeb,
    MediaSessionBridge? mediaBridge,
  }) async {
    final web = isWeb ?? kIsWeb;
    final kv = await PrefsKeyValueStore.open();

    final config = await ApiConfigLoader.load(
      store: kv,
      isWeb: web,
      bundledJson: () async => rootBundle.loadString(
        'assets/api/api_config.json',
      ),
    );

    // 内容源配置（M3）：内置 JSON → 远端覆盖，损坏静默回退内置分类
    final content = await ContentConfigLoader.load(
      store: kv,
      bundledJson: () async => rootBundle.loadString(
        'assets/api/content_config.json',
      ),
    );

    // 儿童白名单配置（M6 / PRD §7.3）：同构加载链路，独立远端缓存 key
    final childrenContent = await ContentConfigLoader.load(
      store: kv,
      bundledJson: () async => rootBundle.loadString(
        'assets/api/children_config.json',
      ),
      builtIn: ContentConfig.childrenBuiltIn,
      cacheKey: ContentConfigLoader.childrenRemoteCacheKey,
    );

    final client = BiliClient(config: config, kv: kv, log: _log);
    await client.initLocal();

    final db = LocalDatabase(kv);
    await db.ensureCreated();

    final theme = ThemeController(kv);
    await theme.load();

    final daos = Daos(db);
    final shelf = ShelfController(daos);
    await shelf.ensure();
    final playUrl = PlayUrlService(client: client, config: config, log: _log);
    final albums = AlbumSource(client: client, config: config, log: _log);
    final discover = DiscoverSource(
      client: client,
      config: config,
      kv: kv,
      log: _log,
    );
    final discoverCache = DiscoverPageCache(kv);
    final progress = ProgressStore(daos);
    final prefs = PlayerPrefs(kv);
    final settings = SettingsStore(kv);
    final account = BiliAccountService(client: client, kv: kv, log: _log);
    final miniPlayer = MiniPlayerController();
    final offline = OfflineCacheService(
      daos: daos,
      playUrl: playUrl,
      albumSource: albums,
      store: createAudioStore(),
      fetcher: DioAudioFetcher(),
      log: _log,
    );
    await offline.initFlags(kv);
    offline.useAudioProxy = web;
    final player = PlayerService(
      playUrl: playUrl,
      albumSource: albums,
      daos: daos,
      store: progress,
      prefs: prefs,
      miniPlayer: miniPlayer,
      saveInterval: const Duration(seconds: 15),
      media: mediaBridge ?? NoopMediaBridge(),
      log: _log,
      shelf: shelf,
      offline: offline,
    );
    // 零网络、零引擎：只挂生命周期/焦点/系统桥 + 读持久化参数
    await player.init();

    // 下载档位跟随默认音质（封顶 192K 由 OfflineCacheService 收口）
    offline.qualityProvider = () => player.quality;

    // 权限同步（Q3）：绑定/大会员态变化 → 播放器档位钳制
    // （解绑→132K、大会员过期→192K 回落，保证「所选即可播」）。
    // 构造期账号态已从本地 Cookie/档案缓存恢复，可直接同步一次；
    // 后续 nav 校准（warmup）与扫码登录/解绑都会经 notifyListeners 再触发。
    void syncEntitlement() {
      player
          .setEntitlement(bound: account.bound, isVip: account.isVip)
          .catchError((Object e) {
        _log('sync entitlement error: $e');
      });
    }

    syncEntitlement();
    account.addListener(syncEntitlement);

    // WebDAV 同步：恢复落库后重载各处内存缓存（主题/书架/播放参数/开关）
    final webdav = WebdavSyncService(
      kv: kv,
      db: db,
      afterRestore: () async {
        await theme.load();
        await shelf.reload();
        player.reloadPrefs();
        settings.notifyChanged();
        await offline.initFlags(kv);
      },
    );

    return AppServices._(
      kv: kv,
      config: config,
      content: content,
      childrenContent: childrenContent,
      client: client,
      db: db,
      daos: daos,
      theme: theme,
      miniPlayer: miniPlayer,
      playUrl: playUrl,
      albums: albums,
      discover: discover,
      discoverCache: discoverCache,
      progress: progress,
      prefs: prefs,
      player: player,
      shelf: shelf,
      settings: settings,
      offline: offline,
      account: account,
      webdav: webdav,
    );
  }

  /// 进主界面后**后台**预热：种 buvid → 激活 → 刷 WBI key（失败静默）。
  void warmupInBackground() {
    client.warmupIfNeeded().catchError((Object e) {
      _log('warmup error: $e');
    });
    // 静默校准 nav（Q9b）：刷新绑定/大会员态（失败保持缓存现状），
    // 成功后经 notifyListeners → syncEntitlement 收口档位钳制。
    account.refreshProfile().catchError((Object e) {
      _log('refresh profile error: $e');
    });
    // 同时装载上次的收听会话（**不自动发声**），让 MiniPlayer 一进来就有内容
    player.restoreLastSession().catchError((Object e) {
      _log('restore session error: $e');
      return false;
    });
  }

  static void _log(String msg) {
    if (kDebugMode) debugPrint('[kele] $msg');
  }
}
