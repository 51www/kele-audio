import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../app/di.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../app/widgets/common.dart';
import '../../../core/data/daos.dart';
import '../../../core/services/listen_stats.dart';
import '../../../core/services/player/player_service.dart';

/// 听书统计页（M8 / PRD §5.6.1）。
///
/// 全部数据来自本地 `play_log` / `album` / `play_history`，不上传任何服务器。
class StatsPage extends StatelessWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final services = context.read<AppServices>();
    final daos = context.read<Daos>();

    // watch PlayerService：播放落进度（play_log 落盘）后自动刷新
    context.watch<PlayerService>();
    final entries = daos.playLogs.all();
    final stats = ListenStats.fromEntries(entries);
    final monthSec = StatsAgg.monthSec(entries);
    final trend = StatsAgg.dailyTrend(entries, days: 14);
    final topCategories = StatsAgg.topCategories(
      entries,
      nameOf: (id) => services.content.byId(id)?.name ??
          services.childrenContent.byId(id)?.name ??
          (id.isEmpty ? '未分类' : id),
    );
    final topAlbums = StatsAgg.topAlbums(
      entries,
      nameOf: (id) => daos.albums.get(id)?.title ?? '未知专辑',
    );
    final finished = StatsAgg.finishedAlbumCount(
      albumIds: daos.albums.all().map((a) => a.id),
      finishedChaptersOf: daos.playHistory.finishedCount,
      totalChaptersOf: (id) {
        final album = daos.albums.get(id);
        return album?.chapterCount ?? daos.chapters.countFor(id);
      },
    );

    return Scaffold(
      appBar: AppBar(title: const Text('听书统计')),
      body: ListView(
        padding: EdgeInsets.all(tokens.spaceMd),
        children: [
          // ── KPI 三卡（今日卡已移除，小屏完整显示不出省略号）──────
          Row(
            children: [
              for (final (i, kpi) in [
                ('本周', ListenStats.formatDuration(stats.weekSec)),
                ('本月', ListenStats.formatDuration(monthSec)),
                ('累计', ListenStats.formatDuration(stats.totalSec)),
              ].indexed) ...[
                if (i > 0) SizedBox(width: tokens.spaceSm),
                Expanded(
                  child: KeleCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 12,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            kpi.$2,
                            style: tokens.titleStyle.copyWith(fontSize: 16),
                            maxLines: 1,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(kpi.$1, style: tokens.captionStyle),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          SizedBox(height: tokens.spaceSm),
          KeleCard(
            child: Row(
              children: [
                Icon(Icons.emoji_events_rounded,
                    size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('累计听完 $finished 张专辑', style: tokens.bodyStyle),
                ),
                Text('数据只存本机', style: tokens.captionStyle),
              ],
            ),
          ),

          // ── 近 14 天趋势 ─────────────────────────────────────────
          const SectionTitle('近 14 天'),
          KeleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TrendBars(trend: trend, tokens: tokens, scheme: scheme),
                SizedBox(height: tokens.spaceSm),
                Text(
                  '每天收听时长（分钟）',
                  style: tokens.captionStyle,
                ),
              ],
            ),
          ),

          // ── 分类 Top3 ────────────────────────────────────────────
          if (topCategories.isNotEmpty) ...[
            const SectionTitle('最常听的分类'),
            KeleCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final (i, c) in topCategories.indexed)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          Text('#${i + 1}', style: tokens.numStyle),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              c.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tokens.bodyStyle,
                            ),
                          ),
                          Text(
                            ListenStats.formatDuration(c.sec),
                            style: tokens.captionStyle,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],

          // ── 专辑 Top5 ────────────────────────────────────────────
          if (topAlbums.isNotEmpty) ...[
            const SectionTitle('最常听的专辑'),
            KeleCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final (i, a) in topAlbums.indexed)
                    InkWell(
                      onTap: () => context.push('/album/${a.id}'),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Text('#${i + 1}', style: tokens.numStyle),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                a.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: tokens.bodyStyle,
                              ),
                            ),
                            Text(
                              ListenStats.formatDuration(a.sec),
                              style: tokens.captionStyle,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],

          if (entries.isEmpty)
            Padding(
              padding: EdgeInsets.only(top: tokens.spaceLg),
              child: const EmptyState(
                icon: Icons.bar_chart_rounded,
                title: '还没有收听数据',
                message: '播放一段时间后，这里会出现你的收听账本。',
              ),
            ),
        ],
      ),
    );
  }
}

/// 近 14 天柱状趋势（纯 Container，不引图表库）。
class _TrendBars extends StatelessWidget {
  const _TrendBars({
    required this.trend,
    required this.tokens,
    required this.scheme,
  });

  final List<({String date, int sec})> trend;
  final AppTokens tokens;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final maxSec = trend.fold<int>(1, (m, e) => e.sec > m ? e.sec : m);
    return SizedBox(
      height: 96,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final e in trend)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      height: e.sec <= 0
                          ? 2
                          : 6 + 84 * e.sec / maxSec,
                      decoration: BoxDecoration(
                        color: e.sec <= 0
                            ? tokens.hairlineColor
                            : scheme.primary.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
