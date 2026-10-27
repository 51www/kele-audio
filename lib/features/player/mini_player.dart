import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/router.dart';
import '../../app/theme/app_tokens.dart';
import '../../core/services/mini_player_controller.dart';
import '../../core/services/player/player_service.dart';

/// 播放条在页面底部的挂载槽位。
///
/// 可见时渲染 [MiniPlayer]，否则塌缩为 0 高度 —— 挂在
/// [Scaffold.bottomNavigationBar] 上，无内容/已关闭时不留空白。
/// 已挂载：Shell（首页三 Tab）、专辑详情、搜索（PRD §4.1 的一级/二级页）；
/// [PlayerPage] 全屏播放页不挂载（此处不显示播放条）。
class MiniPlayerSlot extends StatelessWidget {
  const MiniPlayerSlot({super.key});

  @override
  Widget build(BuildContext context) {
    final visible = context.watch<MiniPlayerController>().visible;
    if (!visible) return const SizedBox.shrink();
    return const MiniPlayer();
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
/// 状态由 `MiniPlayerController`（PlayerService 推送）驱动，进度条按秒节流。
/// 导航走 `AppRouter.router`（部分挂载点拿不到 InheritedGoRouter）。
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

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
        tokens.spaceXs,
      ),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(tokens.radiusPill),
        child: InkWell(
          borderRadius: BorderRadius.circular(tokens.radiusPill),
          // push 进入播放页（go 会清空导航栈，导致播放页向下按钮无栈可弹）
          onTap: () => AppRouter.router.push('/player'),
          child: SizedBox(
            height: 56,
            child: Stack(
              children: [
                // 进度（播放中每秒刷新）
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(tokens.radiusPill),
                    child: LinearProgressIndicator(
                      value: state.progress,
                      minHeight: 3,
                      backgroundColor: fg.withValues(alpha: 0.14),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        scheme.primary,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 7, 4, 7),
                  child: Row(
                    children: [
                      // 封面：有真实封面用图片，否则耳机占位
                      ClipRRect(
                        borderRadius:
                            BorderRadius.circular(tokens.radiusSm + 2),
                        child: SizedBox(
                          width: 40,
                          height: 40,
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
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              state.albumTitle,
                              maxLines: 1,
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
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _placeholderCover(Color fg) => Container(
        width: 40,
        height: 40,
        color: fg.withValues(alpha: 0.14),
        child: Icon(Icons.headphones_rounded, size: 20, color: fg),
      );
}
