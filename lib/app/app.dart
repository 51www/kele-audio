import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api/api_config.dart';
import '../core/api/album_source.dart';
import '../core/api/bili_client.dart';
import '../core/api/play_url_service.dart';
import '../core/data/daos.dart';
import '../core/data/local_database.dart';
import '../core/services/mini_player_controller.dart';
import '../core/services/player/player_service.dart';
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
        Provider<AppServices>.value(value: services),
        Provider<BiliClient>.value(value: services.client),
        Provider<ApiConfig>.value(value: services.config),
        Provider<LocalDatabase>.value(value: services.db),
        Provider<Daos>.value(value: services.daos),
        Provider<PlayUrlService>.value(value: services.playUrl),
        Provider<AlbumSource>.value(value: services.albums),
      ],
      child: Consumer<ThemeController>(
        builder: (context, themeController, _) {
          final mode = themeController.mode;
          return MaterialApp.router(
            title: '可乐听书',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            themeMode: mode,
            routerConfig: AppRouter.router,
          );
        },
      ),
    );
  }
}
