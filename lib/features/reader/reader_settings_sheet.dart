import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import '../../core/services/reader/reader_typography.dart';

/// 阅读排版设置面板（字号 / 行距 / 边距 / 字重 / 翻页模式）。
///
/// 调整即时生效并持久化（`reader_typography`），关闭面板不丢设置。
Future<void> showReaderSettingsSheet(
  BuildContext context, {
  required ReaderTypographyStore store,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => _ReaderSettingsSheet(store: store),
  );
}

class _ReaderSettingsSheet extends StatefulWidget {
  const _ReaderSettingsSheet({required this.store});

  final ReaderTypographyStore store;

  @override
  State<_ReaderSettingsSheet> createState() => _ReaderSettingsSheetState();
}

class _ReaderSettingsSheetState extends State<_ReaderSettingsSheet> {
  late ReaderTypography _value = widget.store.value;

  void _update(ReaderTypography next) {
    setState(() => _value = next);
    widget.store.update(next);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            tokens.spaceMd,
            0,
            tokens.spaceMd,
            tokens.spaceMd,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('阅读排版', style: tokens.sectionStyle),
                  const Spacer(),
                  TextButton(
                    onPressed: () => _update(ReaderTypography.defaults),
                    child: const Text('恢复默认'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              _SliderRow(
                label: '字号',
                valueText: '${_value.fontSize.toStringAsFixed(0)} px',
                value: _value.fontSize,
                min: ReaderTypography.minFontSize,
                max: ReaderTypography.maxFontSize,
                divisions: 12,
                onChanged: (v) => _update(_value.copyWith(fontSize: v)),
              ),
              _SliderRow(
                label: '行距',
                valueText: _value.lineHeight.toStringAsFixed(1),
                value: _value.lineHeight,
                min: ReaderTypography.minLineHeight,
                max: ReaderTypography.maxLineHeight,
                divisions: 10,
                onChanged: (v) => _update(_value.copyWith(lineHeight: v)),
              ),
              _SliderRow(
                label: '边距',
                valueText: '${_value.margin.toStringAsFixed(0)} px',
                value: _value.margin,
                min: ReaderTypography.minMargin,
                max: ReaderTypography.maxMargin,
                divisions: 20,
                onChanged: (v) => _update(_value.copyWith(margin: v)),
              ),
              const SizedBox(height: 8),
              Text('字重', style: tokens.sectionStyle),
              const SizedBox(height: 6),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 400, label: Text('常规')),
                  ButtonSegment(value: 500, label: Text('中等')),
                  ButtonSegment(value: 600, label: Text('加粗')),
                ],
                selected: {_value.weight},
                showSelectedIcon: false,
                onSelectionChanged: (set) =>
                    _update(_value.copyWith(weight: set.first)),
              ),
              const SizedBox(height: 14),
              Text('翻页方式', style: tokens.sectionStyle),
              const SizedBox(height: 6),
              SegmentedButton<ReaderFlow>(
                segments: const [
                  ButtonSegment(
                    value: ReaderFlow.paged,
                    icon: Icon(Icons.auto_stories_outlined),
                    label: Text('翻页'),
                  ),
                  ButtonSegment(
                    value: ReaderFlow.scrolled,
                    icon: Icon(Icons.vertical_align_center_rounded),
                    label: Text('滚动'),
                  ),
                ],
                selected: {_value.flow},
                showSelectedIcon: false,
                onSelectionChanged: (set) =>
                    _update(_value.copyWith(flow: set.first)),
              ),
              SizedBox(height: tokens.spaceSm),
              Text(
                '排版与主题跟随当前皮肤，调整即时生效并在重启后保留。',
                style: tokens.captionStyle.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final String valueText;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Row(
      children: [
        SizedBox(width: 44, child: Text(label, style: tokens.bodyStyle)),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 62,
          child: Text(
            valueText,
            textAlign: TextAlign.end,
            style: tokens.numStyle,
          ),
        ),
      ],
    );
  }
}
