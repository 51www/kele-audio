import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import '../../core/services/system/notification_permission.dart';
import '../../core/services/tts/tts_engine.dart';
import '../../core/services/tts/tts_session.dart';

/// 阅读页听书控制条（M9.3）：启停 / 段落跳转 / 引擎快捷切换 / 语速 / 睡眠定时。
class ReaderTtsBar extends StatelessWidget {
  const ReaderTtsBar({super.key, required this.session});

  final TtsSession session;

  static const List<double> _speedSteps = [0.8, 1.0, 1.25, 1.5, 2.0];

  String _sleepLabel() {
    if (session.stopAfterChapter) return '本章结束';
    final left = session.sleepRemaining;
    if (left == Duration.zero) return '定时';
    final minutes = left.inMinutes;
    final seconds = left.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: session,
      builder: (context, _) {
        final error = session.error;
        return Material(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.96),
          elevation: 6,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spaceMd,
              tokens.spaceSm,
              tokens.spaceXs,
              tokens.spaceSm,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.headphones_rounded,
                      size: 18,
                      color: scheme.primary,
                    ),
                    SizedBox(width: tokens.spaceXs),
                    Expanded(
                      child: Text(
                        session.chapterTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.captionStyle,
                      ),
                    ),
                    Text(
                      '${session.paragraphIndex + 1}/${session.paragraphCount} 段',
                      style: tokens.captionStyle,
                    ),
                    Tooltip(
                      message: '停止朗读',
                      child: TextButton(
                        onPressed: () => session.stop(),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(56, 32),
                          padding: EdgeInsets.symmetric(
                            horizontal: tokens.spaceXs,
                          ),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          '停止',
                          style: tokens.captionStyle.copyWith(
                            color: scheme.error,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    IconButton(
                      tooltip: '上一段',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => session.skipParagraph(-1),
                      icon: const Icon(Icons.skip_previous_rounded),
                    ),
                    IconButton.filledTonal(
                      tooltip: session.playing ? '暂停' : '继续',
                      onPressed: () => session.toggle(),
                      icon: Icon(
                        session.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                    ),
                    IconButton(
                      tooltip: '下一段',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => session.skipParagraph(1),
                      icon: const Icon(Icons.skip_next_rounded),
                    ),
                    const Spacer(),
                    _EngineMenu(session: session),
                    _SpeedButton(session: session, steps: _speedSteps),
                    _SleepMenu(session: session, label: _sleepLabel()),
                  ],
                ),
                if (error != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.only(top: 2, right: tokens.spaceSm),
                      child: Text(
                        '朗读中断：$error',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.captionStyle.copyWith(
                          color: scheme.error,
                        ),
                      ),
                    ),
                  ),
                // 通知权限被拒：朗读不受影响，但后台/锁屏控制降级。
                ValueListenableBuilder<bool>(
                  valueListenable: NotificationPermission.granted,
                  builder: (context, granted, _) {
                    if (granted) return const SizedBox.shrink();
                    return Padding(
                      padding: EdgeInsets.only(
                        top: 2,
                        right: tokens.spaceSm,
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
            ),
          ),
        );
      },
    );
  }
}

class _EngineMenu extends StatelessWidget {
  const _EngineMenu({required this.session});

  final TtsSession session;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return PopupMenuButton<TtsEngineKind>(
      tooltip: '切换朗读引擎',
      initialValue: session.engineKind,
      onSelected: session.switchEngine,
      itemBuilder: (context) => [
        for (final kind in TtsEngineKind.values)
          PopupMenuItem(
            value: kind,
            child: Text(
              kind.label,
              style: session.engineKind == kind
                  ? tokens.bodyStyle.copyWith(
                      fontWeight: FontWeight.w600,
                    )
                  : tokens.bodyStyle,
            ),
          ),
      ],
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: tokens.spaceXs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(session.engineKind.label, style: tokens.captionStyle),
            const Icon(Icons.expand_more_rounded, size: 16),
          ],
        ),
      ),
    );
  }
}

class _SpeedButton extends StatelessWidget {
  const _SpeedButton({required this.session, required this.steps});

  final TtsSession session;
  final List<double> steps;

  Future<void> _cycle() async {
    final current = session.settings.rate;
    final index = steps.indexOf(current);
    final next = steps[(index + 1) % steps.length];
    await session.settings.setRate(next);
    await session.reloadParams();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return TextButton(
      onPressed: _cycle,
      style: TextButton.styleFrom(
        minimumSize: const Size(44, 36),
        padding: EdgeInsets.symmetric(horizontal: tokens.spaceXs),
      ),
      child: Text(
        '${session.settings.rate.toStringAsFixed(session.settings.rate == 1.0 ? 1 : 2)}x',
        style: tokens.captionStyle,
      ),
    );
  }
}

class _SleepMenu extends StatelessWidget {
  const _SleepMenu({required this.session, required this.label});

  final TtsSession session;
  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return PopupMenuButton<int>(
      tooltip: '睡眠定时',
      onSelected: (minutes) =>
          session.setSleepTimer(minutes: minutes < 0 ? null : minutes),
      itemBuilder: (context) => const [
        PopupMenuItem(value: -1, child: Text('取消定时')),
        PopupMenuItem(value: 1, child: Text('1 分钟（验证）')),
        PopupMenuItem(value: 15, child: Text('15 分钟')),
        PopupMenuItem(value: 30, child: Text('30 分钟')),
        PopupMenuItem(value: 60, child: Text('60 分钟')),
        PopupMenuItem(value: 0, child: Text('本章读完停止')),
      ],
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: tokens.spaceXs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bedtime_outlined,
              size: 18,
              color: session.hasSleepTimer
                  ? Theme.of(context).colorScheme.primary
                  : tokens.captionStyle.color,
            ),
            const SizedBox(width: 2),
            Text(label, style: tokens.captionStyle),
          ],
        ),
      ),
    );
  }
}
