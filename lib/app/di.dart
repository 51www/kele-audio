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
import '../core/services/mini_player_controller.dart';
import '../core/services/player/media_bridge.dart';
import '../core/services/player/player_service.dart';
import '../core/services/player/progress_store.dart';
import 'theme/theme_controller.dart';

/// 应用级服务集合（DI）：一次性启动装配，页面用 `context.read` 取用。
class AppServices {
  AppServices._({
    required this.kv,
    required this.config,
    required this.content,
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
  });

  final KeyValueStore kv;
  final ApiConfig config;

  /// 内容源配置（M3：分类 / 查询 / 黑名单，R1 式远端热修复）
  final ContentConfig content;
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

    final client = BiliClient(config: config, kv: kv, log: _log);
    await client.initLocal();

    final db = LocalDatabase(kv);
    await db.ensureCreated();

    final theme = ThemeController(kv);
    await theme.load();

    final daos = Daos(db);
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
    final miniPlayer = MiniPlayerController();
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
    );
    // 零网络、零引擎：只挂生命周期/焦点/系统桥 + 读持久化参数
    await player.init();

    return AppServices._(
      kv: kv,
      config: config,
      content: content,
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
    );
  }

  /// 进主界面后**后台**预热：种 buvid → 激活 → 刷 WBI key（失败静默）。
  void warmupInBackground() {
    client.warmupIfNeeded().catchError((Object e) {
      _log('warmup error: $e');
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
