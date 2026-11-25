import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import '../../core/domain/reader_annotation.dart';

/// 编辑面板只提供黄/绿/蓝三色（粉色仅为兼容历史划线数据保留在枚举中）。
const _editorColors = <ReaderAnnotationColor>[
  ReaderAnnotationColor.yellow,
  ReaderAnnotationColor.green,
  ReaderAnnotationColor.blue,
];

/// 本书划线列表：只看划线文本，右侧编辑/删除。
Future<void> showReaderAnnotationSheet(
  BuildContext context, {
  required String bookTitle,
  required List<ReaderAnnotation> annotations,
  required Future<void> Function(ReaderAnnotation) onEdit,
  required Future<void> Function(ReaderAnnotation) onDelete,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      final tokens = AppTokens.of(sheetContext);
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.78,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  tokens.spaceLg,
                  0,
                  tokens.spaceLg,
                  tokens.spaceSm,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '《$bookTitle》的划线 · ${annotations.length}',
                        style: tokens.sectionStyle,
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: annotations.isEmpty
                    ? Padding(
                        padding: EdgeInsets.all(tokens.spaceLg),
                        child: Text(
                          '还没有划线。长按或拖动选中正文，即可在浮条中点击「划线」。',
                          style: tokens.bodyStyle,
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: annotations.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final item = annotations[index];
                          return ListTile(
                            leading: Container(
                              width: 6,
                              height: 36,
                              decoration: BoxDecoration(
                                color: _color(item.color),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                            title: Text(
                              item.text,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: tokens.bodyStyle,
                            ),
                            onTap: null,
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: '编辑',
                                  icon: const Icon(Icons.edit_outlined, size: 18),
                                  onPressed: () => onEdit(item),
                                ),
                                IconButton(
                                  tooltip: '删除',
                                  icon: const Icon(Icons.delete_outline, size: 18),
                                  onPressed: () => onDelete(item),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// 编辑单条划线：颜色 + 删除。
Future<void> showReaderAnnotationEditorSheet(
  BuildContext context, {
  required ReaderAnnotation annotation,
  required Future<void> Function(ReaderAnnotationColor color) onSave,
  required Future<void> Function() onDelete,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _AnnotationEditor(
      annotation: annotation,
      onSave: onSave,
      onDelete: onDelete,
    ),
  );
}

class _AnnotationEditor extends StatefulWidget {
  const _AnnotationEditor({
    required this.annotation,
    required this.onSave,
    required this.onDelete,
  });

  final ReaderAnnotation annotation;
  final Future<void> Function(ReaderAnnotationColor color) onSave;
  final Future<void> Function() onDelete;

  @override
  State<_AnnotationEditor> createState() => _AnnotationEditorState();
}

class _AnnotationEditorState extends State<_AnnotationEditor> {
  late ReaderAnnotationColor _color;

  @override
  void initState() {
    super.initState();
    _color = widget.annotation.color;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          tokens.spaceLg,
          0,
          tokens.spaceLg,
          MediaQuery.of(context).viewInsets.bottom + tokens.spaceLg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('下划线颜色', style: tokens.sectionStyle),
            SizedBox(height: tokens.spaceMd),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final color in _editorColors)
                  _ColorCard(
                    color: color,
                    selected: _color == color,
                    onTap: () => setState(() => _color = color),
                  ),
              ],
            ),
            SizedBox(height: tokens.spaceLg),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () async {
                    await widget.onDelete();
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('删除'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () async {
                    await widget.onSave(_color);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorCard extends StatelessWidget {
  const _ColorCard({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final ReaderAnnotationColor color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final swatch = _colorOf(color);
    return Semantics(
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          constraints: const BoxConstraints(minWidth: 88, maxWidth: 112),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? swatch.withValues(alpha: 0.18)
                : scheme.surfaceContainerHighest,
            border: Border.all(
              color: selected ? swatch : Colors.transparent,
              width: 2,
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(radius: 8, backgroundColor: swatch),
              SizedBox(width: tokens.spaceSm),
              Text(
                color.label,
                style: selected
                    ? TextStyle(color: swatch, fontWeight: FontWeight.w600)
                    : tokens.bodyStyle,
              ),
              if (selected) ...[
                SizedBox(width: tokens.spaceXs),
                Icon(Icons.check_rounded, size: 16, color: swatch),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

Color _colorOf(ReaderAnnotationColor color) => switch (color) {
      ReaderAnnotationColor.yellow => const Color(0xFFE8B33C),
      ReaderAnnotationColor.green => const Color(0xFF5AAE7A),
      ReaderAnnotationColor.blue => const Color(0xFF4A86D8),
      ReaderAnnotationColor.pink => const Color(0xFFD66B9B),
    };

Color _color(ReaderAnnotationColor color) => _colorOf(color);
