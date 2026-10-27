import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/dev_flags.dart';
import '../../app/theme/app_tokens.dart';
import '../../app/widgets/common.dart';
import '../../core/data/dao_demo.dart';
import '../../core/data/daos.dart';
import '../../core/data/local_database.dart';
import '../../core/services/player/player_service.dart';
import '../../core/services/shelf_controller.dart';
import '../discover/album_card.dart';

/// Tab 2 书架（PRD §5.3，M4 接入）。
///
/// 结构：
/// - 在听置顶区：30 天内有收听且未听完的专辑，卡片 + 进度条，点击续播；
/// - 收藏列表：封面 / 章节进度（已听 x/y）/ 最后收听时间；
/// - 排序：最近收听 / 收藏时间 / 标题；
/// - 长按多选删除、左滑删除（带撤销）；
/// - 空态引导跳发现页。
///
/// 数据来自 [ShelfController.buildViews]（shelf × album × play_history 联合查询），
/// 每次 build 同步重读，保证切回页面 / 收藏状态变化后读到最新进度。
class ShelfPage extends StatefulWidget {
  const ShelfPage({super.key});

  @override
  State<ShelfPage> createState() => _ShelfPageState();
}

enum _SortMode { recent, collected, title }

extension _SortModeX on _SortMode {
  String get label => switch (this) {
    _SortMode.recent => '最近收听',
    _SortMode.collected => '收藏时间',
    _SortMode.title => '标题',
  };
}

class _ShelfPageState extends State<ShelfPage> {
  _SortMode _sort = _SortMode.recent;

  // 多选删除态
  bool _selecting = false;
  final Set<String> _selected = {};

  // M1 数据层自检（保留：M1 准出证据，且 widget_test 依赖其文案）
  DaoDemoReport? _report;
  bool _running = false;
  Map<String, int> _counts = const {};

  Future<void> _runDemo() async {
    final daos = context.read<Daos>();
    setState(() => _running = true);
    final report = await runDaoDemo(daos);
    final counts = await daos.db.counts();
    if (!mounted) return;
    setState(() {
      _report = report;
      _counts = counts;
      _running = false;
    });
  }

  // ───────────────────────────────────────────────────────── 续播
  Future<void> _resume(String albumId) async {
    final daos = context.read<Daos>();
    final album = daos.albums.get(albumId);
    if (album == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('这本需要先播放过，本地还没有章节数据')));
      return;
    }
    final player = context.read<PlayerService>();
    await player.playAlbum(album); // 不指定章节 → 自动续播到最后听的章节
    if (!mounted) return;
    context.push('/player');
  }

  // ───────────────────────────────────────────────────────── 删除
  Future<void> _deleteOne(ShelfView view) async {
    final shelf = context.read<ShelfController>();
    final removed = view.item;
    await shelf.remove(view.item.albumId);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('已移除「${view.title}」'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () => shelf.restore(removed),
          ),
        ),
      );
  }

  Future<void> _deleteSelected() async {
    final shelf = context.read<ShelfController>();
    final ids = [..._selected];
    await shelf.removeAll(ids);
    if (!mounted) return;
    setState(() {
      _selecting = false;
      _selected.clear();
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('已删除 ${ids.length} 本')));
  }

  // ───────────────────────────────────────────────────────── 排序
  List<ShelfView> _sorted(List<ShelfView> views) {
    final list = [...views];
    switch (_sort) {
      case _SortMode.recent:
        list.sort((a, b) => b.lastPlayedAt.compareTo(a.lastPlayedAt));
      case _SortMode.collected:
        list.sort((a, b) => b.collectedAt.compareTo(a.collectedAt));
      case _SortMode.title:
        list.sort((a, b) => a.title.compareTo(b.title));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    // watch：收藏状态变化（详情/播放页 toggle）实时反映到书架
    final shelf = context.watch<ShelfController>();
    final db = context.read<LocalDatabase>();

    final views = shelf.buildViews();
    final listening = views.where((v) => v.inListening).toList()
      ..sort((a, b) => b.lastPlayedAt.compareTo(a.lastPlayedAt));
    final sorted = _sorted(views);

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: EdgeInsets.only(bottom: tokens.spaceLg),
        children: [
          PageHeader(
            title: '书架',
            subtitle: '收藏与在听 · 全部数据仅存本机',
            actions: _selecting
                ? [
                    TextButton(
                      onPressed: () => setState(() {
                        _selecting = false;
                        _selected.clear();
                      }),
                      child: const Text('取消'),
                    ),
                  ]
                : [
                    IconButton(
                      tooltip: '选择删除',
                      onPressed: () => setState(() {
                        _selecting = true;
                        _selected.clear();
                      }),
                      icon: const Icon(Icons.checklist_rounded),
                    ),
                    PopupMenuButton<_SortMode>(
                      tooltip: '排序',
                      icon: const Icon(Icons.sort_rounded),
                      onSelected: (m) => setState(() => _sort = m),
                      itemBuilder: (_) => [
                        for (final m in _SortMode.values)
                          PopupMenuItem(
                            value: m,
                            child: Row(
                              children: [
                                if (_sort == m)
                                  Icon(
                                    Icons.check_rounded,
                                    size: 18,
                                    color: scheme.primary,
                                  )
                                else
                                  const SizedBox(width: 18),
                                const SizedBox(width: 8),
                                Text(m.label),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
          ),

          // ── 多选删除操作条 ───────────────────────────────────────
          if (_selecting)
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spaceMd,
                0,
                tokens.spaceMd,
                tokens.spaceSm,
              ),
              child: KeleCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Text('已选 ${_selected.length} 本', style: tokens.bodyStyle),
                    const Spacer(),
                    TextButton(
                      onPressed: () => setState(() {
                        if (_selected.length == views.length) {
                          _selected.clear();
                        } else {
                          _selected
                            ..clear()
                            ..addAll(views.map((v) => v.item.albumId));
                        }
                      }),
                      child: Text(
                        _selected.length == views.length ? '取消全选' : '全选',
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: _selected.isEmpty ? null : _deleteSelected,
                      child: const Text('删除'),
                    ),
                  ],
                ),
              ),
            ),

          // ── 在听置顶区 ───────────────────────────────────────────
          if (listening.isNotEmpty) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spaceMd,
                tokens.spaceLg,
                tokens.spaceMd,
                0,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.graphic_eq_rounded,
                    color: scheme.primary,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text('在听', style: tokens.sectionStyle),
                  const SizedBox(width: 8),
                  StageTag('续播', tone: StageTone.accent),
                ],
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 150,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: tokens.spaceMd),
                itemCount: listening.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, i) =>
                    _ListeningCard(view: listening[i], onTap: _resume),
              ),
            ),
          ],

          // ── 收藏列表 ─────────────────────────────────────────────
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spaceMd,
              tokens.spaceLg,
              tokens.spaceMd,
              0,
            ),
            child: SectionTitle(
              '收藏列表',
              trailing: Text('排序 · ${_sort.label}', style: tokens.captionStyle),
            ),
          ),
          if (sorted.isEmpty)
            EmptyState(
              icon: Icons.favorite_border_rounded,
              title: '书架还是空的',
              message: '在详情页或播放页点「加入书架」，\n常听的内容就会收在这里。',
              actionLabel: '去发现页逛逛',
              onAction: () => context.go('/discover'),
            )
          else
            for (final v in sorted)
              _ShelfRow(
                view: v,
                selecting: _selecting,
                selected: _selected.contains(v.item.albumId),
                onTap: () {
                  if (_selecting) {
                    setState(() {
                      if (_selected.contains(v.item.albumId)) {
                        _selected.remove(v.item.albumId);
                      } else {
                        _selected.add(v.item.albumId);
                      }
                    });
                  } else {
                    _resume(v.item.albumId);
                  }
                },
                onLongPress: () => setState(() {
                  _selecting = true;
                  _selected.add(v.item.albumId);
                }),
                onDelete: () => _deleteOne(v),
              ),

          // ── 本地数据层自检（M1 准出证据；DevFlags 开启才渲染） ────
          if (DevFlags.showPanels)
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spaceMd,
                tokens.spaceLg,
                tokens.spaceMd,
                0,
              ),
              child: KeleCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.storage_rounded,
                          size: 18,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '本地数据层 · core/data',
                            style: tokens.sectionStyle,
                          ),
                        ),
                        const StageTag('M1 准出', tone: StageTone.accent),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '六张表（PRD §7.5）：${LocalDatabase.tableNames.join(' · ')}',
                      style: tokens.captionStyle,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      db.createResult?.describe ?? '表尚未创建',
                      style: tokens.numStyle,
                    ),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: _running ? null : _runDemo,
                      child: Text(_running ? '运行中…' : '运行建表 + DAO 读写 Demo'),
                    ),
                    if (_report != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: scheme.onSurface.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(tokens.radiusSm),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  _report!.ok
                                      ? Icons.check_circle_rounded
                                      : Icons.error_rounded,
                                  size: 16,
                                  color: _report!.ok
                                      ? scheme.secondary
                                      : scheme.error,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    _report!.summary,
                                    style: tokens.numStyle.copyWith(
                                      color: _report!.ok
                                          ? scheme.secondary
                                          : scheme.error,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            for (final s in _report!.steps)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 2,
                                ),
                                child: Text(
                                  '· $s',
                                  style: tokens.captionStyle.copyWith(
                                    fontFamily: 'monospace',
                                    fontSize: 11.5,
                                  ),
                                ),
                              ),
                            if (_counts.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                '表行数：${_counts.entries.map((e) => '${e.key}=${e.value}').join('  ')}',
                                style: tokens.captionStyle.copyWith(
                                  fontFamily: 'monospace',
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 在听置顶区卡片：封面 + 标题 + 进度条，点击续播。
class _ListeningCard extends StatelessWidget {
  const _ListeningCard({required this.view, required this.onTap});

  final ShelfView view;
  final void Function(String albumId) onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 140,
      child: KeleCard(
        onTap: () => onTap(view.item.albumId),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(tokens.radiusSm),
              child: SizedBox(
                width: double.infinity,
                height: 64,
                child: CoverImage(url: view.coverUrl, title: view.title),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              view.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.bodyStyle.copyWith(
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: view.lastChapterPercent / 100,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
            ),
            const SizedBox(height: 4),
            Text(
              view.totalChapters > 0
                  ? '已听 ${view.finishedCount}/${view.totalChapters}'
                  : '尚未收听',
              style: tokens.captionStyle,
            ),
          ],
        ),
      ),
    );
  }
}

/// 收藏列表单行：封面 + 标题 + UP + 进度 + 最后收听时间。
/// 左滑删除（Dismissible），长按进入多选，多选态显示勾选。
class _ShelfRow extends StatelessWidget {
  const _ShelfRow({
    required this.view,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onDelete,
  });

  final ShelfView view;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;

    final row = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: selecting ? null : onLongPress,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            tokens.spaceMd,
            tokens.spaceSm,
            tokens.spaceMd,
            tokens.spaceSm,
          ),
          child: Row(
            children: [
              if (selecting)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    color: selected ? scheme.primary : tokens.onHairline,
                  ),
                ),
              ClipRRect(
                borderRadius: BorderRadius.circular(tokens.radiusSm),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: CoverImage(url: view.coverUrl, title: view.title),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      view.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.bodyStyle.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(view.upName, style: tokens.captionStyle),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Text(
                          view.totalChapters > 0
                              ? '已听 ${view.finishedCount}/${view.totalChapters}'
                              : '尚未收听',
                          style: tokens.captionStyle.copyWith(
                            color: scheme.primary,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          _fmtLastPlayed(view.lastPlayedAt),
                          style: tokens.captionStyle,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (selecting) return row;
    return Dismissible(
      key: ValueKey(view.item.albumId),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        decoration: BoxDecoration(
          color: scheme.error.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(tokens.radiusMd),
        ),
        child: Icon(Icons.delete_outline_rounded, color: scheme.error),
      ),
      confirmDismiss: (_) async => true,
      onDismissed: (_) => onDelete(),
      child: row,
    );
  }

  static String _fmtLastPlayed(int ms) {
    if (ms <= 0) return '未收听';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final diff = today.difference(day).inDays;
    final hm =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (diff == 0) return '今天 $hm';
    if (diff == 1) return '昨天 $hm';
    if (diff < 7) return '$diff 天前';
    return '${t.month}/${t.day}';
  }
}
