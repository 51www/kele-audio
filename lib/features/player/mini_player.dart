import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/theme/app_tokens.dart';
import '../../core/services/mini_player_controller.dart';

/// 全局播放条（PRD §4.1）：悬浮在 Bottom Navigation 之上，点击展开播放页。
///
/// M1 占位态：无播放任务时展示「未在播放」，点击仍可进入 `/player` 占位页。
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final state = context.watch<MiniPlayerController>().state;

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
          onTap: () => context.go('/player'),
          child: SizedBox(
            height: 56,
            child: Stack(
              children: [
                // 进度（M1 恒为 0，M2 由播放进度驱动）
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
                  padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
                  child: Row(
                    children: [
                      // 封面占位
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: fg.withValues(alpha: 0.14),
                          borderRadius:
                              BorderRadius.circular(tokens.radiusSm + 2),
                        ),
                        child: Icon(
                          Icons.headphones_rounded,
                          size: 20,
                          color: fg,
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
                              state.hasTask ? state.chapterTitle : '播放核心将在 M2 接入',
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
                      Icon(
                        state.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: scheme.primary,
                        size: 30,
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
}
