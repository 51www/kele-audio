import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/router.dart';
import '../../app/theme/app_tokens.dart';
import '../../app/widgets/progress_ring.dart';
import '../../core/services/mini_player_controller.dart';
import '../../core/services/player/player_service.dart';

/// 播放条在页面底部的挂载槽位。
///
/// 可见时渲染 [MiniPlayer]，否则塌缩为 0 高度 —— 挂在
/// [Scaffold.bottomNavigationBar] 上，无内容/已关闭时不留空白。
/// 已挂载：Shell（首页三 Tab）、专辑详情、搜索（PRD §4.1 的一级/二级页）；
/// [PlayerPage] 全屏播放页不挂载（此处不显示播放条）。
class MiniPlayerSlot extends StatelessWidget {
  const MiniPlayerSlot({super.key, this.alignToHomeBar = false});

  /// 二级页（专辑详情、搜索）没有底部导航栏，播放条会直接贴到屏幕底。
  /// 置 true 时在播放条下方预留与首页 [NavigationBar] 等高的空间，
  /// 让两处播放条距屏幕底部完全一致。
  ///
  /// 首页（[HomeShell]）保持默认 false —— 导航栏本身已在播放条下方占位。
  final bool alignToHomeBar;

  @override
  Widget build(BuildContext context) {
    final visible = context.watch<MiniPlayerController>().visible;
    if (!visible) return const SizedBox.shrink();

    if (!alignToHomeBar) return const MiniPlayer();

    // 高度直接读主题（AppTheme 里显式设为 60），改主题时这里自动跟随；
    // 底部安全区取 padding 而非 viewPadding，与 NavigationBar 内部 SafeArea 同源，
    // 键盘弹起时两边一起收起，不会一边贴键盘一边悬空。
    final navHeight = Theme.of(context).navigationBarTheme.height ?? 80.0;
    final inset = MediaQuery.paddingOf(context).bottom;
    return MiniPlayer(bottomGap: navHeight + inset);
  }
}

/// 全局播放条（PRD §4.1）：悬浮于页面底部，点击展开播放页。
///
/// 显隐规则（由 [MiniPlayerSlot] 按 [MiniPlayerController.visible] 挂载）：
/// - 无播放内容 → 不显示；
/// - 点 ✕ 关闭 → 收起（正在播放则先暂停），开始新播放任务时自动回来。
///
/// 交互语义：
/// - 点条身 → 跳转播放页；
/// - ▶（暂停态）→ 开始播放并跳转播放页（非播放页点播放按钮直达播放页）；
/// - ⏸（播放态）→ 原地暂停，不离开当前页；
/// - ✕ → 暂停并关闭播放条。
///
/// 状态由 `MiniPlayerController`（PlayerService 推送）驱动；章节进度不再占一条
/// 通栏细线，而是画在封面外圈（[ProgressRing]）——秒级 tick 由环自身的
/// 补间动画吸收，不会突兀跳变。
/// 导航走 `AppRouter.router`（部分挂载点拿不到 InheritedGoRouter）。
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, this.bottomGap = 0});

  /// 胶囊下方的额外留白：二级页没有底部导航栏时用它把播放条抬到
  /// 与首页同一水平线（[MiniPlayerSlot.alignToHomeBar]）。
  final double bottomGap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final controller = context.watch<MiniPlayerController>();
    final state = controller.state;
    final player = context.read<PlayerService>();

    // 双保险：无播放内容不渲染（MiniPlayerSlot 已按 visible 挂载，此处兜底）
    if (!state.hasTask) return const SizedBox.shrink();

    // 反相胶囊：浅色主题下是深棕胶囊，深色主题下是暖白胶囊——
    // 颜色全部来自 ColorScheme，天然适配儿童模式（M6 换主题即可）。
    final bg = scheme.onSurface;
    final fg = scheme.surface;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spaceMd,
        tokens.spaceSm,
        tokens.spaceMd,
        tokens.spaceXs + bottomGap,
      ),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(tokens.radiusPill),
        child: InkWell(
          borderRadius: BorderRadius.circular(tokens.radiusPill),
          // push 进入播放页（go 会清空导航栈，导致播放页向下按钮无栈可弹）
          onTap: () => AppRouter.router.push('/player'),
          // 高度下限 56（正好容纳 42 的进度环 + 上下 7 内边距）；
          // 标题折行时由内容撑高，不再把文字压掉。
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 7, 4, 7),
              child: Row(
                children: [
                  // 封面外圈 = 章节进度环（替代原底部通栏进度条）：
                  // 0% 只有轨道底环，100% 闭合成整圆。
                  ProgressRing(
                    value: state.progress,
                    size: 42,
                    strokeWidth: 2.5,
                    gap: 1.5,
                    color: scheme.primary,
                    trackColor: fg.withValues(alpha: 0.18),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(tokens.radiusSm),
                      child: SizedBox.expand(
                        child: state.coverUrl.isEmpty
                            ? _placeholderCover(fg)
                            : Image.network(
                                state.coverUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) =>
                                    _placeholderCover(fg),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    // 与 NavigationBar 同策略：钳制系统字号放大倍数，
                    // 否则大字号下两行字会变成五六行、把播放条撑得很高。
                    child: MediaQuery.withClampedTextScaling(
                      maxScaleFactor: 1.2,
                      child: Column(
                        // min：播放条在底栏槽位里收到的是有界高度，
                        // 默认 max 会让整条胶囊被拉满屏（二级页特别明显）。
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 专辑名最多六行：320 宽 + 大字号下也能读全
                          // （条高由内容撑开）；只有极端超长才省略。
                          Text(
                            state.albumTitle,
                            maxLines: 6,
                            overflow: TextOverflow.ellipsis,
                            style: tokens.bodyStyle.copyWith(
                              color: fg,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                              height: 1.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            state.chapterTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tokens.captionStyle.copyWith(
                              color: fg.withValues(alpha: 0.66),
                              height: 1.25,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: state.playing ? '暂停' : '播放',
                    onPressed: () {
                      if (state.playing) {
                        // 暂停：原地生效，不离开当前页
                        unawaited(player.pause());
                      } else {
                        // 播放：非播放页点播放按钮 → 直达播放页
                        unawaited(player.play());
                        AppRouter.router.push('/player');
                      }
                    },
                    icon: Icon(
                      state.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: scheme.primary,
                      size: 30,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭播放条',
                    onPressed: () {
                      // 关闭 = 正在播先暂停（不留下无条的后台播放）+ 收起；
                      // 下次点某一集 / 播放全部 / 续播时自动重新显示
                      if (state.playing) unawaited(player.pause());
                      controller.close();
                    },
                    icon: Icon(
                      Icons.close_rounded,
                      color: fg.withValues(alpha: 0.55),
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 无封面时的耳机占位：尺寸由外层 [ProgressRing] 的内容区决定。
  Widget _placeholderCover(Color fg) => Container(
    color: fg.withValues(alpha: 0.14),
    alignment: Alignment.center,
    child: Icon(Icons.headphones_rounded, size: 16, color: fg),
  );
}
