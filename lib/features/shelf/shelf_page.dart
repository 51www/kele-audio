import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/theme/app_tokens.dart';
import '../../app/widgets/common.dart';
import '../../core/data/daos.dart';
import '../../core/data/dao_demo.dart';
import '../../core/data/local_database.dart';

/// Tab 2 书架（PRD §5.3）。
///
/// M1 范围：页面骨架 + 空态引导 + **本地数据层自检**（建表 & DAO 读写 Demo）；
/// M4 接入收藏、进度、排序、删除。
class ShelfPage extends StatefulWidget {
  const ShelfPage({super.key});

  @override
  State<ShelfPage> createState() => _ShelfPageState();
}

class _ShelfPageState extends State<ShelfPage> {
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

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final db = context.read<LocalDatabase>();

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: EdgeInsets.only(bottom: tokens.spaceLg),
        children: [
          PageHeader(
            title: '书架',
            subtitle: '收藏与在听 · 全部数据仅存本机',
            actions: [
              IconButton(
                tooltip: '排序 · M4 接入',
                onPressed: () => ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(const SnackBar(
                    content: Text('排序（最近收听 / 收藏时间 / 标题）将在 M4 接入'),
                  )),
                icon: const Icon(Icons.sort_rounded),
              ),
            ],
          ),

          // ── 在听置顶区（M4） ──────────────────────────────────────
          Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.spaceMd),
            child: KeleCard(
              child: Row(
                children: [
                  Icon(Icons.graphic_eq_rounded, color: scheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('在听置顶区', style: tokens.sectionStyle),
                        const SizedBox(height: 4),
                        Text(
                          '30 天内听过、且没听完的专辑会出现在这里，点开即续播。',
                          style: tokens.captionStyle,
                        ),
                      ],
                    ),
                  ),
                  const StageTag('M4 接入', tone: StageTone.accent),
                ],
              ),
            ),
          ),

          const SectionTitle('收藏列表'),
          const EmptyState(
            icon: Icons.favorite_border_rounded,
            title: '书架还是空的',
            message: '在详情页或播放页点「加入书架」，\n常听的内容就会收在这里。',
            actionLabel: '去发现页逛逛',
          ),
          Center(
            child: OutlinedButton.icon(
              onPressed: () => context.go('/discover'),
              icon: const Icon(Icons.explore_outlined, size: 18),
              label: const Text('去发现页'),
            ),
          ),

          // ── 本地数据层自检（M1 准出） ─────────────────────────────
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
                      Icon(Icons.storage_rounded,
                          size: 18, color: scheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('本地数据层 · core/data',
                            style: tokens.sectionStyle),
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
                              padding:
                                  const EdgeInsets.symmetric(vertical: 2),
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
