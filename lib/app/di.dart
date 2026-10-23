import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/api/api_config.dart';
import '../core/api/bili_client.dart';
import '../core/api/key_value_store.dart';
import '../core/api/prefs_kv_store.dart';
import '../core/data/daos.dart';
import '../core/data/local_database.dart';
import '../core/services/mini_player_controller.dart';
import 'theme/theme_controller.dart';

/// 应用级服务集合（DI）：一次性启动装配，页面用 `context.read` 取用。
class AppServices {
  AppServices._({
    required this.kv,
    required this.config,
    required this.client,
    required this.db,
    required this.daos,
    required this.theme,
    required this.miniPlayer,
  });

  final KeyValueStore kv;
  final ApiConfig config;
  final BiliClient client;
  final LocalDatabase db;
  final Daos daos;
  final ThemeController theme;
  final MiniPlayerController miniPlayer;

  /// 启动装配：**不发任何网络请求**（PRD 冷启动 ≤ 3s）。
  ///
  /// 顺序：本地 KV → 接口配置（内置 JSON，R1 远端覆盖失败静默）→
  /// Dio 本地初始化 → 建表 → 主题读取。
  static Future<AppServices> bootstrap({bool? isWeb}) async {
    final web = isWeb ?? kIsWeb;
    final kv = await PrefsKeyValueStore.open();

    final config = await ApiConfigLoader.load(
      store: kv,
      isWeb: web,
      bundledJson: () async => rootBundle.loadString(
        'assets/api/api_config.json',
      ),
    );

    final client = BiliClient(config: config, kv: kv, log: _log);
    await client.initLocal();

    final db = LocalDatabase(kv);
    await db.ensureCreated();

    final theme = ThemeController(kv);
    await theme.load();

    return AppServices._(
      kv: kv,
      config: config,
      client: client,
      db: db,
      daos: Daos(db),
      theme: theme,
      miniPlayer: MiniPlayerController(),
    );
  }

  /// 进主界面后**后台**预热：种 buvid → 激活 → 刷 WBI key（失败静默）。
  void warmupInBackground() {
    client.warmupIfNeeded().catchError((Object e) {
      _log('warmup error: $e');
    });
  }

  static void _log(String msg) {
    if (kDebugMode) debugPrint('[kele] $msg');
  }
}
