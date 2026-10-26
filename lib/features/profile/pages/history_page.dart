import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/widgets/common.dart';
import '../../../core/data/daos.dart';
import '../../../core/services/history_service.dart';
import '../../../core/services/player/player_service.dart';
import '../../discover/album_card.dart';

/// 历史收听页（PRD §5.6.2，M5 实装）。
///
/// - 专辑级聚合列表（封面、标题、最后播放章节与进度、时间）；
/// - 今天 / 昨天 / 日期分组，组内新→旧；
/// - 左滑单条删除（带撤销）、顶部「清空」（二次确认）；
/// - 点击 → 续播（复用 M2 `playAlbum` 自动定位最后章节）；
/// - 列表按滚动增量构建（本地数据全量在内存，"分页"= 懒构建）。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  late final HistoryService _history = HistoryService(context.read<Daos>());

  Future<void> _resume(HistoryEntryView entry) async {
    final daos = context.read<Daos>();
    final album = daos.albums.get(entry.albumId);
    if (album == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('这本缺少本地章节数据，去详情页重新打开一下'),
        ));
      return;
    }
    final player = context.read<PlayerService>();
    await player.playAlbum(album); // 不指定章节 → P-04 定位最后听的章节
    if (!mounted) return;
    context.push('/player');
  }

  Future<void> _deleteOne(HistoryEntryView entry) async {
    final removed = await _history.removeAlbum(entry.albumId);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('已删除「${entry.title}」的收听记录'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () async {
            await _history.restore(removed);
            if (mounted) setState(() {});
          },
        ),
      ));
  }

  Future<void> _confirmClear(List<HistoryEntryView> entries) async {
    if (entries.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空全部历史？'),
        content: Text('将删除 ${entries.length} 本专辑的收听记录（含断点续播点），此操作不可撤销。\n'
            '书架收藏的专辑条目不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _history.clear();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('历史已清空')));
  }

  static String _timeOf(int playedAt) {
    final d = DateTime.fromMillisecondsSinceEpoch(playedAt);
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final entries = _history.buildEntries();
    final groups = HistoryService.groupByDay(entries);
    final rows = _flatten(groups);

    return Scaffold(
      appBar: AppBar(
        title: const Text('历史收听'),
        actions: [
          TextButton(
            onPressed:
                entries.isEmpty ? null : () => _confirmClear(entries),
            child: const Text('清空'),
          ),
        ],
      ),
      body: entries.isEmpty
          ? EmptyState(
              icon: Icons.history_rounded,
              title: '还没有收听记录',
              message: '播放过的内容会自动收在这里，\n随时点开接着听。',
              actionLabel: '去发现页逛逛',
              onAction: () => context.go('/discover'),
            )
          : ListView.builder(
              padding: EdgeInsets.only(bottom: tokens.spaceLg),
              // 懒构建：分组头 + 条目打平后按滚动增量构建（分页语义）
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final row = rows[index];
                return switch (row) {
                  _RowHeader() => _GroupHeader(label: row.label, count: row.count),
                  _RowEntry() => _HistoryRow(
                      entry: row.entry,
                      time: _timeOf(row.entry.playedAt),
                      onTap: () => _resume(row.entry),
                      onDelete: () => _deleteOne(row.entry),
                    ),
                };
              },
            ),
    );
  }
}

/// 打平分组为列表行（分组头 + 条目），供 ListView.builder 懒构建。
sealed class _Row {}

class _RowHeader extends _Row {
  _RowHeader(this.label, this.count);
  final String label;
  final int count;
}

class _RowEntry extends _Row {
  _RowEntry(this.entry);
  final HistoryEntryView entry;
}

List<_Row> _flatten(List<HistoryDayGroup> groups) {
  final rows = <_Row>[];
  for (final g in groups) {
    rows.add(_RowHeader(g.label, g.entries.length));
    rows.addAll(g.entries.map(_RowEntry.new));
  }
  return rows;
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spaceMd,
        tokens.spaceLg,
        tokens.spaceMd,
        tokens.spaceXs,
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 14,
            decoration: BoxDecoration(
              gradient: tokens.accentGradient,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(label, style: tokens.sectionStyle),
          const SizedBox(width: 8),
          Text('$count 本', style: tokens.captionStyle),
        ],
      ),
    );
  }
}

/// 历史单行：封面 + 标题 + 最后播放章节与进度 + 时间；左滑删除（带撤销）。
class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.entry,
    required this.time,
    required this.onTap,
    required this.onDelete,
  });

  final HistoryEntryView entry;
  final String time;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Dismissible(
      key: ValueKey(entry.albumId),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: scheme.errorContainer,
        child: Icon(Icons.delete_outline_rounded, color: scheme.onErrorContainer),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spaceMd,
              tokens.spaceSm,
              tokens.spaceMd,
              tokens.spaceSm,
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(tokens.radiusSm),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: CoverImage(url: entry.coverUrl, title: entry.title),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.bodyStyle.copyWith(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        entry.lastChapterTitle.isEmpty
                            ? '最后播放章节未知'
                            : '最后播放：${entry.lastChapterTitle}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.captionStyle,
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Expanded(
                            child: LinearProgressIndicator(
                              value: entry.percent / 100,
                              minHeight: 4,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            entry.percent >= 90 ? '已听完' : '已听 ${entry.percent}%',
                            style: tokens.captionStyle,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(time, style: tokens.captionStyle),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
