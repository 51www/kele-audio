import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/theme/app_tokens.dart';
import '../../core/domain/album.dart';
import '../../core/domain/playback.dart';
import '../../core/services/player/player_service.dart';
import '../../core/services/shelf_controller.dart';

/// 播放页（PRD §5.4）—— M2：真实播放控制。
///
/// 结构：封面 → 标题 → 进度条（独立节流，不整页刷新）→ 控制区 →
/// 功能区（倍速/定时/音质/章节/模式）→ 加入书架。
/// 状态一律来自 [PlayerService]（唯一事实源）。
class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final player = context.watch<PlayerService>();
    final chapter = player.currentChapter;
    final album = player.album;

    return Scaffold(
      appBar: AppBar(
        title: const Text('播放'),
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: [
          // 演练菜单：debug/profile 构建可见（release 不出现）
          if (!kReleaseMode)
            PopupMenuButton<String>(
              tooltip: '验收演练',
              icon: const Icon(Icons.bug_report_outlined),
              onSelected: (v) {
                if (v == 'expire') {
                  player.debugExpireCurrentUrl();
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(const SnackBar(
                      content: Text('P-05 演练：已作废当前地址，观察自动重取续播'),
                    ));
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'expire',
                  child: Text('模拟地址失效（P-05 演练）'),
                ),
              ],
            ),
        ],
      ),
      body: SafeArea(
        child: !player.hasSession
            ? const _IdleView()
            : Padding(
                padding: EdgeInsets.symmetric(horizontal: tokens.spaceLg),
                child: Column(
                  children: [
                    SizedBox(height: tokens.spaceLg),
                    _Cover(coverUrl: album?.coverUrl ?? ''),
                    SizedBox(height: tokens.spaceLg),
                    Text(
                      album?.title ?? '未选择内容',
                      style: tokens.titleStyle,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      chapter?.title ?? '准备播放',
                      style: tokens.captionStyle,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (player.error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        player.error!,
                        style: tokens.captionStyle.copyWith(color: scheme.error),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    SizedBox(height: tokens.spaceLg),

                    // 进度条：位置更新走 positionTick（独立刷新，不整页重建）
                    _ProgressBar(player: player),
                    SizedBox(height: tokens.spaceMd),

                    // 控制区
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          onPressed: player.hasPrev ? player.previous : null,
                          icon: const Icon(Icons.skip_previous_rounded),
                          iconSize: 34,
                        ),
                        const SizedBox(width: 8),
                        _PlayButton(player: player),
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: player.hasNext ? player.next : null,
                          icon: const Icon(Icons.skip_next_rounded),
                          iconSize: 34,
                        ),
                      ],
                    ),
                    SizedBox(height: tokens.spaceMd),

                    // 功能区
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: tokens.spaceSm,
                      runSpacing: tokens.spaceSm,
                      children: [
                        _FeatureChip(
                          icon: Icons.speed_rounded,
                          label: player.rateLabel,
                          onTap: () => _showSpeedSheet(context, player),
                        ),
                        _FeatureChip(
                          icon: Icons.bedtime_outlined,
                          label: _sleepLabel(player),
                          onTap: () => _showSleepSheet(context, player),
                        ),
                        _FeatureChip(
                          icon: Icons.tune_rounded,
                          label: player.quality.label,
                          onTap: () => _showQualitySheet(context, player),
                        ),
                        _FeatureChip(
                          icon: Icons.playlist_play_rounded,
                          label: '章节 ${player.chapters.length}',
                          onTap: () => _showChapterSheet(context, player),
                        ),
                        _FeatureChip(
                          icon: _modeIcon(player.mode),
                          label: player.mode.label,
                          onTap: () => player.setMode(nextMode(player.mode)),
                        ),
                      ],
                    ),
                    const Spacer(),
                    SizedBox(
                      width: double.infinity,
                      child: _ShelfButton(album: album),
                    ),
                    SizedBox(height: tokens.spaceMd),
                  ],
                ),
              ),
      ),
    );
  }

  static IconData _modeIcon(PlayMode m) => switch (m) {
        PlayMode.sequential => Icons.repeat_rounded,
        PlayMode.loopAll => Icons.repeat_rounded,
        PlayMode.loopOne => Icons.repeat_one_rounded,
      };

  static PlayMode nextMode(PlayMode m) => switch (m) {
        PlayMode.sequential => PlayMode.loopAll,
        PlayMode.loopAll => PlayMode.loopOne,
        PlayMode.loopOne => PlayMode.sequential,
      };

  static String _sleepLabel(PlayerService p) {
    if (p.stopAtChapterEnd) return '本章结束';
    if (!p.hasSleepTimer) return '定时';
    final m = p.sleepRemaining.inMinutes;
    final s = p.sleepRemaining.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  // ------------------------------------------------------------------ 面板

  static void _showSpeedSheet(BuildContext context, PlayerService player) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('倍速', style: AppTokens.of(context).sectionStyle),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final v in PlayerService.speedSteps)
                    ChoiceChip(
                      label: Text('${_rateText(v)}x'),
                      selected: (v - player.rate).abs() < 0.001,
                      onSelected: (_) async {
                        await player.setRate(v);
                        if (context.mounted) Navigator.of(context).pop();
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  static String _rateText(double v) => v == v.roundToDouble()
      ? '${v.toInt()}'
      : v
          .toStringAsFixed(2)
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');

  static void _showSleepSheet(BuildContext context, PlayerService player) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: StatefulBuilder(
          builder: (context, setState) {
            final tokens = AppTokens.of(context);
            Widget option(
              String label,
              bool selected,
              Future<void> Function() onTap,
            ) =>
                ListTile(
                  dense: true,
                  title: Text(label, style: tokens.bodyStyle),
                  trailing: selected
                      ? Icon(Icons.check_rounded,
                          color: Theme.of(context).colorScheme.primary)
                      : null,
                  onTap: () async {
                    await onTap();
                    if (context.mounted) Navigator.of(context).pop();
                  },
                );
            final none = !player.hasSleepTimer && !player.stopAtChapterEnd;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Row(
                    children: [
                      Text('定时关闭', style: tokens.sectionStyle),
                      const Spacer(),
                      if (player.hasSleepTimer || player.stopAtChapterEnd)
                        TextButton(
                          onPressed: () async {
                            await player.cancelSleepTimer();
                            if (context.mounted) {
                              Navigator.of(context).pop();
                            }
                          },
                          child: const Text('关闭'),
                        ),
                    ],
                  ),
                ),
                // PRD §5.4：关闭 / 5 / 10 / 15 / 30 / 45 / 60 分钟 / 本章结束
                option('本章结束', player.stopAtChapterEnd,
                    () => player.setSleepTimer(minutes: 0)),
                for (final m in const [5, 10, 15, 30, 45, 60])
                  option('$m 分钟', _sel(player, m, none),
                      () => player.setSleepTimer(minutes: m)),
                option('关闭', none, () => player.cancelSleepTimer()),
                const SizedBox(height: 12),
              ],
            );
          },
        ),
      ),
    );
  }

  static bool _sel(PlayerService p, int minutes, bool none) {
    if (none || !p.hasSleepTimer || p.stopAtChapterEnd) return false;
    final diff = p.sleepRemaining.inMinutes - minutes;
    return diff == 0 || diff == -1;
  }

  static void _showQualitySheet(BuildContext context, PlayerService player) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text('音质', style: AppTokens.of(context).sectionStyle),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final q in AudioQuality.values)
                    ChoiceChip(
                      label: Text(q.label),
                      selected: q == player.quality,
                      onSelected: (_) async {
                        await player.setQuality(q);
                        if (context.mounted) Navigator.of(context).pop();
                      },
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
              child: Text(
                '切换音质会重新取址并从当前进度续播；'
                'B 站并非每条内容都有全部档位，缺失时自动退到最接近的一档。',
                style: AppTokens.of(context).captionStyle,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static void _showChapterSheet(BuildContext context, PlayerService player) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        builder: (context, controller) {
          final tokens = AppTokens.of(context);
          final scheme = Theme.of(context).colorScheme;
          final chapters = player.chapters;
          return ListView.builder(
            controller: controller,
            padding: const EdgeInsets.only(bottom: 16),
            itemCount: chapters.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text('章节目录（${chapters.length}）',
                      style: tokens.sectionStyle),
                );
              }
              final c = chapters[i - 1];
              final current = i - 1 == player.index;
              return ListTile(
                dense: true,
                selected: current,
                selectedTileColor: scheme.primary.withValues(alpha: 0.08),
                leading: Text(
                  current && player.playing
                      ? '▶'
                      : i.toString().padLeft(2, '0'),
                  style: tokens.numStyle.copyWith(
                    color: current ? scheme.primary : null,
                  ),
                ),
                title: Text(
                  c.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.bodyStyle.copyWith(
                    color: current ? scheme.primary : null,
                    fontWeight: current ? FontWeight.w700 : null,
                  ),
                ),
                trailing: Text(_fmtDur(c.durationSec),
                    style: tokens.captionStyle),
                onTap: () {
                  player.playChapterAt(i - 1);
                  Navigator.of(context).pop();
                },
              );
            },
          );
        },
      ),
    );
  }

  static String _fmtDur(int sec) {
    if (sec <= 0) return '--:--';
    return fmtClock(Duration(seconds: sec));
  }
}

// ─────────────────────────────────────────────────────────────── 子部件

class _IdleView extends StatelessWidget {
  const _IdleView();

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final player = context.watch<PlayerService>();

    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: tokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.headphones_rounded,
                size: 56, color: scheme.onSurfaceVariant),
            SizedBox(height: tokens.spaceMd),
            Text('未选择内容', style: tokens.titleStyle),
            const SizedBox(height: 6),
            Text(
              player.error ??
                  '在发现页点开专辑选一章开始收听；听过的专辑会在这里续播',
              textAlign: TextAlign.center,
              style: tokens.bodyStyle,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => context.go('/discover'),
              icon: const Icon(Icons.explore_outlined, size: 18),
              label: const Text('去发现页'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.coverUrl});

  final String coverUrl;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const size = 230.0;
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary.withValues(alpha: 0.92),
            scheme.secondary.withValues(alpha: 0.7),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.28),
            blurRadius: 40,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: Center(
        child: Container(
          width: 74,
          height: 74,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.surface.withValues(alpha: 0.92),
          ),
          child: Icon(Icons.headphones_rounded, color: scheme.primary, size: 34),
        ),
      ),
    );
    if (coverUrl.isEmpty) return placeholder;
    return ClipOval(
      child: Image.network(
        coverUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.player});

  final PlayerService player;

  @override
  Widget build(BuildContext context) {
    final busy = player.loading || player.recovering;
    final IconData icon;
    if (busy) {
      icon = Icons.hourglass_top_rounded;
    } else if (player.buffering) {
      icon = Icons.wifi_tethering_rounded;
    } else {
      icon = player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded;
    }
    return FilledButton(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.all(0),
        minimumSize: const Size(72, 72),
        shape: const CircleBorder(),
      ),
      onPressed: busy ? null : player.toggle,
      child: busy
          ? const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2.6),
            )
          : Icon(icon, size: 42),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.player});

  final PlayerService player;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Column(
      children: [
        ValueListenableBuilder<Duration>(
          valueListenable: player.positionTick,
          builder: (context, pos, _) {
            final total = player.duration.inMilliseconds;
            final value = total <= 0
                ? 0.0
                : (pos.inMilliseconds / total).clamp(0.0, 1.0);
            return Slider(
              value: value,
              onChanged: total <= 0
                  ? null
                  : (v) {
                      player.seek(
                        Duration(milliseconds: (v * total).round()),
                      );
                    },
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              ValueListenableBuilder<Duration>(
                valueListenable: player.positionTick,
                builder: (context, pos, _) =>
                    Text(fmtClock(pos), style: tokens.numStyle),
              ),
              Text(fmtClock(player.duration), style: tokens.numStyle),
            ],
          ),
        ),
      ],
    );
  }
}

class _ShelfButton extends StatelessWidget {
  const _ShelfButton({required this.album});

  final Album? album;

  @override
  Widget build(BuildContext context) {
    if (album == null) return const SizedBox.shrink();
    // watch：收藏状态实时反映（加入/取消书架）
    final shelf = context.watch<ShelfController>();
    final inShelf = shelf.has(album!.id);
    return OutlinedButton.icon(
      onPressed: () async {
        final wasIn = shelf.has(album!.id);
        await shelf.toggle(album!.id);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(wasIn
                ? '已移出书架：${album!.title}'
                : '已加入书架：${album!.title}'),
          ));
      },
      icon: Icon(
        inShelf ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        size: 18,
      ),
      label: Text(inShelf ? '已收藏' : '加入书架'),
    );
  }
}

class _FeatureChip extends StatelessWidget {
  const _FeatureChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(tokens.radiusPill),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(tokens.radiusPill),
          border: Border.all(color: tokens.hairlineColor),
          color: scheme.surfaceContainer,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: scheme.primary),
            const SizedBox(width: 6),
            Text(
              label,
              style: tokens.captionStyle.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 时长格式化（导出给 MiniPlayer / 详情页复用）
String fmtClock(Duration d) {
  if (d < Duration.zero) return '00:00';
  final total = d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
