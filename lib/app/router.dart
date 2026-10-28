import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/discover/album_detail_page.dart';
import '../features/discover/discover_page.dart';
import '../features/discover/search_page.dart';
import '../features/profile/pages/about_page.dart';
import '../features/profile/pages/bili_account_page.dart';
import '../features/profile/pages/downloads_page.dart';
import '../features/profile/pages/history_page.dart';
import '../features/profile/pages/settings_page.dart';
import '../features/profile/pages/stats_page.dart';
import '../features/profile/profile_page.dart';
import '../features/player/player_page.dart';
import '../features/shelf/shelf_page.dart';
import 'home_shell.dart';

/// 路由表（PRD §4.2 十条路由）。
///
/// - 三个 Tab 走 [StatefulShellRoute.indexedStack]：**状态与滚动位置不销毁**；
/// - 二级页挂在 `/profile` 分支内，返回后 MiniPlayer 不丢（PRD §5.6 准出）；
/// - `/player`、`/album/:id` 是全屏路由，自带 Scaffold（无底栏）。
class AppRouter {
  AppRouter._();

  static final GoRouter router = GoRouter(
    initialLocation: '/discover',
    debugLogDiagnostics: false,
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            HomeShell(navigationShell: navigationShell),
        branches: [
          // 1. 发现
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/discover',
              name: 'discover',
              builder: (context, state) => const DiscoverPage(),
            ),
          ]),
          // 2. 书架
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/shelf',
              name: 'shelf',
              builder: (context, state) => const ShelfPage(),
            ),
          ]),
          // 3. 我的（含 5 个二级页）
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/profile',
              name: 'profile',
              builder: (context, state) => const ProfilePage(),
              routes: [
                // 6. 历史收听
                GoRoute(
                  path: 'history',
                  name: 'profile-history',
                  builder: (context, state) => const HistoryPage(),
                ),
                // 7. 离线缓存管理
                GoRoute(
                  path: 'downloads',
                  name: 'profile-downloads',
                  builder: (context, state) => const DownloadsPage(),
                ),
                // 8. 设置
                GoRoute(
                  path: 'settings',
                  name: 'profile-settings',
                  builder: (context, state) => const SettingsPage(),
                ),
                // 12. B 站账号绑定（设置 → 账号绑定）
                GoRoute(
                  path: 'bili-account',
                  name: 'profile-bili-account',
                  builder: (context, state) => const BiliAccountPage(),
                ),
                // 9. 关于/版本
                GoRoute(
                  path: 'about',
                  name: 'profile-about',
                  builder: (context, state) => const AboutPage(),
                ),
                // 10. 听书统计
                GoRoute(
                  path: 'stats',
                  name: 'profile-stats',
                  builder: (context, state) => const StatsPage(),
                ),
              ],
            ),
          ]),
        ],
      ),
      // 4. 播放页（全屏，全局唯一）
      GoRoute(
        path: '/player',
        name: 'player',
        pageBuilder: (context, state) => MaterialPage(
          key: state.pageKey,
          fullscreenDialog: false,
          child: const PlayerPage(),
        ),
      ),
      // 5. 专辑详情
      GoRoute(
        path: '/album/:id',
        name: 'album',
        builder: (context, state) => AlbumDetailPage(
          albumId: state.pathParameters['id'] ?? '',
        ),
      ),
      // 11. 搜索（M8）：`?q=` 支持编辑精选专题卡预置关键词
      GoRoute(
        path: '/search',
        name: 'search',
        builder: (context, state) => SearchPage(
          initialKeyword: state.uri.queryParameters['q'] ?? '',
        ),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.explore_off_rounded, size: 40),
            const SizedBox(height: 12),
            Text('页面不存在：${state.uri}'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => context.go('/discover'),
              child: const Text('回到发现页'),
            ),
          ],
        ),
      ),
    ),
  );
}
