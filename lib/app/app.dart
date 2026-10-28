import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api/api_config.dart';
import '../core/api/album_source.dart';
import '../core/api/bili_client.dart';
import '../core/api/content_config.dart';
import '../core/api/discover_source.dart';
import '../core/api/play_url_service.dart';
import '../core/data/daos.dart';
import '../core/data/discover_cache.dart';
import '../core/data/local_database.dart';
import '../core/services/bili_account_service.dart';
import '../core/services/mini_player_controller.dart';
import '../core/services/offline/offline_cache_service.dart';
import '../core/services/player/player_service.dart';
import '../core/services/settings_store.dart';
import '../core/services/shelf_controller.dart';
import 'di.dart';
import 'router.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';

/// 根组件：DI 装配 + 主题 + 路由。
class KeleApp extends StatelessWidget {
  const KeleApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeController>.value(value: services.theme),
        ChangeNotifierProvider<MiniPlayerController>.value(
          value: services.miniPlayer,
        ),
        ChangeNotifierProvider<PlayerService>.value(value: services.player),
        ChangeNotifierProvider<ShelfController>.value(value: services.shelf),
        ChangeNotifierProvider<SettingsStore>.value(value: services.settings),
        ChangeNotifierProvider<BiliAccountService>.value(
          value: services.account,
        ),
        Provider<AppServices>.value(value: services),
        Provider<BiliClient>.value(value: services.client),
        Provider<ApiConfig>.value(value: services.config),
        Provider<LocalDatabase>.value(value: services.db),
        Provider<Daos>.value(value: services.daos),
        Provider<PlayUrlService>.value(value: services.playUrl),
        Provider<AlbumSource>.value(value: services.albums),
        Provider<ContentConfig>.value(value: services.content),
        ChangeNotifierProvider<OfflineCacheService>.value(
          value: services.offline,
        ),
        Provider<DiscoverSource>.value(value: services.discover),
        Provider<DiscoverPageCache>.value(value: services.discoverCache),
      ],
      child: Consumer<ThemeController>(
        builder: (context, themeController, _) {
          // 单一主题槽位：用户可自由切换任意预设（默认主题1「暖纸书卷」）；
          // 进入儿童模式时自动套用主题4「春日活力」（见 ThemeController.setChildren）。
          // 六个预设都是完整皮肤（含深色的主题3/6/7），切换即换肤（无重启）。
          return MaterialApp.router(
            title: '可乐听书',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.of(themeController.preset),
            themeMode: ThemeMode.light,
            routerConfig: AppRouter.router,
          );
        },
      ),
    );
  }
}
