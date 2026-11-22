import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme/app_tokens.dart';
import '../../app/widgets/common.dart';
import '../../core/domain/reader_annotation.dart';
import '../../core/services/reader/annotation_export.dart';
import '../../core/services/reader/annotation_export_delivery.dart';
import '../../core/services/reader/reader_annotation_store.dart';

/// 全局划线入口：按书分组查看全部划线文本，支持导出为纯文本。
class AnnotationsPage extends StatelessWidget {
  const AnnotationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final store = context.watch<ReaderAnnotationStore>();
    final items = store.all;
    final groups = _groupByBook(items);

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的划线'),
        actions: [
          IconButton(
            tooltip: '导出划线文本',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: items.isEmpty ? null : () => _export(context, items),
          ),
        ],
      ),
      body: items.isEmpty
          ? const EmptyState(
              icon: Icons.edit_note_rounded,
              title: '还没有划线',
              message: '阅读本地书时选中文字，点击浮条中的「划线」，标记会集中显示在这里。',
            )
          : ListView.builder(
              padding: EdgeInsets.only(
                left: tokens.spaceMd,
                right: tokens.spaceMd,
                top: tokens.spaceMd,
                bottom: tokens.spaceLg,
              ),
              itemCount: groups.length,
              itemBuilder: (context, index) {
                final group = groups[index];
                return Padding(
                  padding: EdgeInsets.only(bottom: tokens.spaceLg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SectionTitle(
                        '${group.title} · ${group.items.length}',
                        padding: EdgeInsets.zero,
                      ),
                      SizedBox(height: tokens.spaceSm),
                      KeleCard(
                        padding: EdgeInsets.zero,
                        child: Column(
                          children: [
                            for (final item in group.items) ...[
                              _AnnotationTile(item: item),
                              const Divider(height: 1),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Future<void> _export(BuildContext context, List<ReaderAnnotation> items) async {
    final fileName = AnnotationExportService.suggestedFileName(DateTime.now());
    try {
      await deliverAnnotationFile(
        fileName: fileName,
        bytes: AnnotationExportService.buildText(items),
        mimeType: 'text/plain',
      );
    } on UnsupportedError catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message ?? '当前平台不支持导出')));
    }
  }
}

class _BookGroup {
  _BookGroup(this.bookId, this.title, this.items);

  final String bookId;
  final String title;
  final List<ReaderAnnotation> items;
}

List<_BookGroup> _groupByBook(List<ReaderAnnotation> items) {
  final map = <String, _BookGroup>{};
  for (final item in items) {
    final group = map.putIfAbsent(
      item.bookId,
      () => _BookGroup(item.bookId, item.bookTitle, <ReaderAnnotation>[]),
    );
    group.items.add(item);
  }
  return map.values.toList();
}

class _AnnotationTile extends StatelessWidget {
  const _AnnotationTile({required this.item});

  final ReaderAnnotation item;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spaceMd,
        tokens.spaceMd,
        tokens.spaceSm,
        tokens.spaceSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.text, style: tokens.bodyStyle),
          SizedBox(height: tokens.spaceSm),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Container(
                width: 4,
                height: 16,
                decoration: BoxDecoration(
                  color: _colorOf(item.color),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              SizedBox(width: tokens.spaceXs),
              IconButton(
                tooltip: '删除',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                icon: Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                onPressed: () => _confirmDelete(context),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这条划线？'),
        content: const Text('删除后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await context.read<ReaderAnnotationStore>().remove(item.bookId, item.id);
  }
}

Color _colorOf(ReaderAnnotationColor color) => switch (color) {
      ReaderAnnotationColor.yellow => const Color(0xFFE8B33C),
      ReaderAnnotationColor.green => const Color(0xFF5AAE7A),
      ReaderAnnotationColor.blue => const Color(0xFF4A86D8),
      ReaderAnnotationColor.pink => const Color(0xFFD66B9B),
    };
