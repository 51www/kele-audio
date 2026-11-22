import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import '../../core/services/reader/reader_bridge.dart';

/// 目录抽屉：正序 / 倒序切换，点条目跳章。
Future<void> showReaderTocSheet(
  BuildContext context, {
  required List<ReaderTocItem> items,
  required int currentIndex,
  required ValueChanged<ReaderTocItem> onSelect,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => _ReaderTocSheet(
      items: items,
      currentIndex: currentIndex,
      onSelect: (item) {
        Navigator.of(sheetContext).pop();
        onSelect(item);
      },
    ),
  );
}

class _ReaderTocSheet extends StatefulWidget {
  const _ReaderTocSheet({
    required this.items,
    required this.currentIndex,
    required this.onSelect,
  });

  final List<ReaderTocItem> items;
  final int currentIndex;
  final ValueChanged<ReaderTocItem> onSelect;

  @override
  State<_ReaderTocSheet> createState() => _ReaderTocSheetState();
}

class _ReaderTocSheetState extends State<_ReaderTocSheet> {
  bool _descending = false;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final list = _descending ? widget.items.reversed.toList() : widget.items;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.62,
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spaceMd,
                0,
                tokens.spaceSm,
                0,
              ),
              child: Row(
                children: [
                  Text('目录', style: tokens.sectionStyle),
                  const SizedBox(width: 8),
                  Text(
                    '${widget.items.length} 章',
                    style: tokens.captionStyle,
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => setState(() => _descending = !_descending),
                    icon: Icon(
                      _descending
                          ? Icons.arrow_downward_rounded
                          : Icons.arrow_upward_rounded,
                      size: 16,
                    ),
                    label: Text(_descending ? '倒序' : '正序'),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: tokens.hairlineColor),
            Expanded(
              child: widget.items.isEmpty
                  ? Center(
                      child: Text(
                        '目录解析中…',
                        style: tokens.bodyStyle.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (context, i) {
                        final item = list[i];
                        final selected = item.index == widget.currentIndex;
                        return ListTile(
                          dense: true,
                          selected: selected,
                          title: Text(
                            item.label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: tokens.bodyStyle.copyWith(
                              color: selected ? scheme.primary : null,
                              fontWeight:
                                  selected ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                          onTap: () => widget.onSelect(item),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
