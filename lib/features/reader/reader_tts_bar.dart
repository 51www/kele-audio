import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_tokens.dart';
import '../../core/services/system/notification_permission.dart';
import '../../core/services/tts/tts_session.dart';
import 'reader_tts_compact_bar.dart';

/// 阅读页听书简洁控制条（M9.5）。
///
/// 只保留章节 / 段进度 / 播放暂停 / 停止：语速、引擎、睡眠定时、章节目录等
/// 细节统一收进听书播放页（`/listen/:id`，与全局 mini 条同一路由、同一会话）。
/// 点条身进播放页；停止留在阅读页，避免退出朗读后找不到收口入口。
/// 主体复用 [ReaderTtsCompactBar]，与 [TtsMiniPlayerSlot] 是同一套视觉与交互。
class ReaderTtsBar extends StatelessWidget {
  const ReaderTtsBar({super.key, required this.session});

  final TtsSession session;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: session,
      builder: (context, _) {
        final bookId = session.bookId;
        final canOpen = bookId != null && bookId.isNotEmpty;
        final error = session.error;
        final count = session.paragraphCount;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ReaderTtsCompactBar(
              title: session.chapterTitle,
              subtitle: count > 0
                  ? '第 ${session.paragraphIndex + 1} / $count 段'
                  : '正文待载入',
              playing: session.playing,
              onToggle: session.toggle,
              onStop: session.stop,
              onOpen: canOpen ? () => context.push('/listen/$bookId') : null,
            ),
            if (error != null)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  tokens.spaceSm,
                  2,
                  tokens.spaceSm,
                  0,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '朗读中断：$error',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.captionStyle.copyWith(color: scheme.error),
                  ),
                ),
              ),
            // 通知权限被拒：朗读不受影响，但后台/锁屏控制降级。
            ValueListenableBuilder<bool>(
              valueListenable: NotificationPermission.granted,
              builder: (context, granted, _) {
                if (granted) return const SizedBox.shrink();
                return Padding(
                  padding: EdgeInsets.fromLTRB(
                    tokens.spaceSm,
                    2,
                    tokens.spaceSm,
                    0,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.notifications_off_outlined,
                        size: 16,
                        color: scheme.error,
                      ),
                      SizedBox(width: tokens.spaceXs),
                      Expanded(
                        child: Text(
                          '未授予通知权限，后台/锁屏控制不可用',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tokens.captionStyle.copyWith(
                            color: scheme.error,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: NotificationPermission.openSettings,
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 32),
                          padding: EdgeInsets.symmetric(
                            horizontal: tokens.spaceXs,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                        child: Text('去开启', style: tokens.captionStyle),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}
