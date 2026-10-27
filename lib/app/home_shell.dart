import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/player/mini_player.dart';

/// 三 Tab 壳：Bottom Navigation（PRD §4.1）。
/// 播放条（[MiniPlayerSlot]）浮于底栏之上，无播放内容/已关闭时自动塌缩。
///
/// `StatefulNavigationShell` 由 [StatefulShellRoute.indexedStack] 提供，
/// 每个分支用 IndexedStack 保持状态 —— 三 Tab 切换**保留滚动位置**。
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const _destinations = [
    (icon: Icons.explore_outlined, active: Icons.explore_rounded, label: '发现'),
    (icon: Icons.menu_book_outlined, active: Icons.menu_book_rounded, label: '书架'),
    (icon: Icons.person_outline_rounded, active: Icons.person_rounded, label: '我的'),
  ];

  void _go(BuildContext context, int index) {
    navigationShell.goBranch(
      index,
      // 再次点当前 Tab：回到该 Tab 的根路由（常见交互）
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: ColoredBox(
        color: scheme.surface,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 播放条浮于底栏之上；无内容/已关闭时塌缩为 0 高度。
            const MiniPlayerSlot(),
            NavigationBar(
              selectedIndex: navigationShell.currentIndex,
              onDestinationSelected: (i) => _go(context, i),
              destinations: [
                for (final d in _destinations)
                  NavigationDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.active),
                    label: d.label,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
