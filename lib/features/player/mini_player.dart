import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/theme/app_tokens.dart';
import '../../core/services/mini_player_controller.dart';
import '../../core/services/player/player_service.dart';

/// 全局播放条（PRD §4.1）：悬浮在 Bottom Navigation 之上，点击展开播放页。
///
/// M2 起接 [PlayerService] 真实状态：封面、专辑/章节、播放/暂停、进度。
/// 状态由 `MiniPlayerController`（PlayerService 推送）驱动，进度条按秒节流。
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final state = context.watch<MiniPlayerController>().state;
    final player = context.read<PlayerService>();

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
          onTap: () => context.push('/player'),
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
                  padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
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
                              state.hasTask ? state.albumTitle : '未在播放',
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
                              state.hasTask
                                  ? state.chapterTitle
                                  : '去发现页挑一张专辑开始收听',
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
                        onPressed: state.hasTask ? player.toggle : null,
                        icon: Icon(
                          state.playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: state.hasTask
                              ? scheme.primary
                              : fg.withValues(alpha: 0.4),
                          size: 30,
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
