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
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  /// 趋势图区间：false = 周统计（近 7 天），true = 月统计（近 30 天）。
  bool _monthly = false;

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
    final trend = StatsAgg.dailyTrend(entries, days: _monthly ? 30 : 7);
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
    final trendTotalSec = trend.fold<int>(0, (s, e) => s + e.sec);
    final totalMin = (trendTotalSec / 60).round();
    final avgMin = (trendTotalSec / 60 / trend.length).round();
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

          // ── 收听趋势（周 / 月切换 + 渐变柱状图）─────────────────
          const SectionTitle('收听趋势'),
          KeleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(
                                '$totalMin',
                                style: tokens.titleStyle
                                    .copyWith(fontSize: 24),
                              ),
                              const SizedBox(width: 4),
                              Text('分钟', style: tokens.captionStyle),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text('日均 $avgMin 分钟', style: tokens.captionStyle),
                        ],
                      ),
                    ),
                    SizedBox(width: tokens.spaceSm),
                    _RangeToggle(
                      monthly: _monthly,
                      onChanged: (v) => setState(() => _monthly = v),
                      tokens: tokens,
                    ),
                  ],
                ),
                SizedBox(height: tokens.spaceMd),
                _TrendChart(
                  trend: trend,
                  monthly: _monthly,
                  tokens: tokens,
                ),
                SizedBox(height: tokens.spaceSm),
                Text('每天收听时长（分钟）', style: tokens.captionStyle),
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

/// 收听趋势柱状图（纯 Container + 主题渐变，不引图表库）。
///
/// 左侧 Y 轴刻度（单位：分钟），底部 X 轴刻度：
/// 周统计标「周一~周日」，月统计每 5 天标一个「M/d」。
class _TrendChart extends StatelessWidget {
  const _TrendChart({
    required this.trend,
    required this.monthly,
    required this.tokens,
  });

  final List<({String date, int sec})> trend;
  final bool monthly;
  final AppTokens tokens;

  static const _weekLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  static const _yAxisWidth = 34.0;
  static const _chartHeight = 132.0;

  @override
  Widget build(BuildContext context) {
    final maxSec = trend.fold<int>(1, (m, e) => e.sec > m ? e.sec : m);
    final maxMin = (maxSec / 60).ceil();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: _chartHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Y 轴：最大值 / 中间值 / 0 刻度（单位见下方图注「分钟」）
              SizedBox(
                width: _yAxisWidth,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('$maxMin', style: tokens.captionStyle),
                    Text('${maxMin ~/ 2}', style: tokens.captionStyle),
                    Text('0', style: tokens.captionStyle),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Stack(
                  children: [
                    // 横向网格线（画在柱后；对齐 Y 轴三条刻度：最大/中间/0）
                    Positioned.fill(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          for (var i = 0; i < 3; i++)
                            Container(
                              height: 1,
                              color: tokens.hairlineColor
                                  .withValues(alpha: 0.4),
                            ),
                        ],
                      ),
                    ),
                    // 纵向网格线（画在柱后；位于 X 轴有刻度的柱位）
                    Positioned.fill(
                      child: Row(
                        children: [
                          for (final (i, _) in trend.indexed)
                            Expanded(
                              child: (!monthly || i % 5 == 0)
                                  ? Center(
                                      child: Container(
                                        width: 1,
                                        color: tokens.hairlineColor
                                            .withValues(alpha: 0.55),
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                        ],
                      ),
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (final e in trend)
                          Expanded(
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 1.5),
                              child: _TrendBar(
                                sec: e.sec,
                                maxSec: maxSec,
                                showValue: !monthly,
                                tokens: tokens,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        // X 轴刻度：按柱位比例定位（标签宽度不受单柱格子约束，避免被裁剪）
        Padding(
          padding: const EdgeInsets.only(left: _yAxisWidth + 4),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final n = trend.length;
              return SizedBox(
                height: 14,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (final (i, e) in trend.indexed)
                      if (_xLabel(e.date, i).isNotEmpty)
                        Positioned(
                          left: (i + 0.5) / n * constraints.maxWidth,
                          child: FractionalTranslation(
                            translation: i == 0
                                ? const Offset(-0.2, 0)
                                : const Offset(-0.5, 0),
                            child: Text(
                              _xLabel(e.date, i),
                              maxLines: 1,
                              style: tokens.captionStyle.copyWith(fontSize: 9),
                            ),
                          ),
                        ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  String _xLabel(String date, int index) {
    final d = DateTime.tryParse(date);
    if (d == null) return '';
    if (!monthly) return _weekLabels[d.weekday - 1];
    return index % 5 == 0 ? '${d.month}/${d.day}' : '';
  }
}

/// 单根趋势柱：数据天为品牌点缀渐变（底部深 → 顶部浅），空数据画发丝线。
class _TrendBar extends StatelessWidget {
  const _TrendBar({
    required this.sec,
    required this.maxSec,
    required this.showValue,
    required this.tokens,
  });

  final int sec;
  final int maxSec;
  final bool showValue;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    final colors = (tokens.accentGradient as LinearGradient).colors;
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (showValue && sec > 0) ...[
          Text(
            '${(sec / 60).round()}',
            style: tokens.captionStyle.copyWith(fontSize: 9),
          ),
          const SizedBox(height: 2),
        ],
        Container(
          height: sec <= 0 ? 2 : 6 + 110 * sec / maxSec,
          decoration: BoxDecoration(
            color: sec <= 0 ? tokens.hairlineColor : null,
            gradient: sec <= 0
                ? null
                : LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: colors,
                  ),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ],
    );
  }
}

/// 周统计 / 月统计切换（胶囊按钮，选中用 primary 实底）。
class _RangeToggle extends StatelessWidget {
  const _RangeToggle({
    required this.monthly,
    required this.onChanged,
    required this.tokens,
  });

  final bool monthly;
  final ValueChanged<bool> onChanged;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget chip(String label, bool selected, VoidCallback onTap) => InkWell(
          borderRadius: BorderRadius.circular(tokens.radiusPill),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: selected ? scheme.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(tokens.radiusPill),
              border: Border.all(
                color: selected ? Colors.transparent : tokens.hairlineColor,
              ),
            ),
            child: Text(
              label,
              style: tokens.captionStyle.copyWith(
                fontWeight: FontWeight.w600,
                color: selected ? scheme.onPrimary : tokens.onHairline,
              ),
            ),
          ),
        );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        chip('周统计', !monthly, () => onChanged(false)),
        const SizedBox(width: 6),
        chip('月统计', monthly, () => onChanged(true)),
      ],
    );
  }
}
