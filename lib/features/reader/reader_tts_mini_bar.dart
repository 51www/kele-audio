import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme/app_tokens.dart';
import '../../core/services/tts/tts_engine.dart';
import '../../core/services/tts/tts_session.dart';

/// 本地书朗读的全局常驻播放条。
///
/// 与 B 站听书播放条（`MiniPlayer`）同一形态：反相胶囊、56 高、圆角、底部留白；
/// 阅读页内用完整控制条 [ReaderTtsBar]，其余页面挂本组件，因此不会出现两条控制条。
/// 停止（✕）会终止朗读并让播放条消失。
class TtsMiniPlayerSlot extends StatelessWidget {
  const TtsMiniPlayerSlot({super.key, this.alignToHomeBar = false});

  /// 二级页没有底部导航栏时，预留与首页导航栏等高的空间，保持与首页同一水平线。
  final bool alignToHomeBar;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TtsSession>();
    if (!session.active) return const SizedBox.shrink();

    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final bg = scheme.onSurface;
    final fg = scheme.surface;
    final bottomGap = alignToHomeBar
        ? (Theme.of(context).navigationBarTheme.height ?? 80.0) +
            MediaQuery.paddingOf(context).bottom
        : 0.0;
    final title = session.chapterTitle.isEmpty ? '本地书朗读' : session.chapterTitle;

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
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 7, 4, 7),
            child: Row(
              children: [
                Icon(Icons.headphones_rounded, color: scheme.primary, size: 26),
                const SizedBox(width: 12),
                Expanded(
                  child: MediaQuery.withClampedTextScaling(
                    maxScaleFactor: 1.2,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
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
                          '${session.engineKind.label} · '
                          '${session.paragraphIndex + 1}/${session.paragraphCount} 段',
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
                  tooltip: session.playing ? '暂停朗读' : '继续朗读',
                  onPressed: () => session.toggle(),
                  icon: Icon(
                    session.playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: scheme.primary,
                    size: 30,
                  ),
                ),
                IconButton(
                  tooltip: '停止朗读',
                  onPressed: () => session.stop(),
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
    );
  }
}
