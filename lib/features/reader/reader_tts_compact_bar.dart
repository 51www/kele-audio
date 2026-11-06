import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import '../../app/widgets/common.dart';

/// 听书简洁条主体。
///
/// 全局 mini 条与阅读页控制条共用同一个组件，保证两处是同一套视觉与交互：
/// 品牌渐变图标位 + 标题/副标题两行 + 反相播放圆钮 + 关闭（停止朗读）。
/// 语速 / 引擎 / 睡眠定时 / 章节目录等细节统一放在听书播放页。
class ReaderTtsCompactBar extends StatelessWidget {
  const ReaderTtsCompactBar({
    super.key,
    required this.title,
    required this.subtitle,
    required this.playing,
    required this.onToggle,
    required this.onStop,
    this.onOpen,
  });

  /// 第一行：书名或当前章节。
  final String title;

  /// 第二行：章节名或段落进度。
  final String subtitle;

  final bool playing;
  final VoidCallback onToggle;

  /// 关闭 = 停止朗读（两处都保留，避免退出朗读后无处收口）。
  final VoidCallback onStop;

  /// 点条身进听书播放页。
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return KeleCard(
      onTap: onOpen,
      padding: const EdgeInsets.fromLTRB(8, 7, 4, 7),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: tokens.accentGradient,
                borderRadius: BorderRadius.circular(tokens.radiusSm),
              ),
              child: Icon(
                Icons.headphones_rounded,
                color: tokens.onAccent,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              // 与导航栏同策略：钳制系统字号放大，避免两行字撑高控制条。
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
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.captionStyle.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: playing ? '暂停朗读' : '继续朗读',
              child: Material(
                color: scheme.onSurface,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onToggle,
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(
                      playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: scheme.surface,
                      size: 24,
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: '停止朗读',
              onPressed: onStop,
              icon: Icon(
                Icons.close_rounded,
                color: scheme.onSurfaceVariant,
                size: 20,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
