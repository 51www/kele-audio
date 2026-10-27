import 'package:flutter/material.dart';

import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';

/// 主题皮肤选择器：五张「色卡」（`docs/theme.md` 主题 1~5）。
///
/// 每张色卡用**该主题自己的配色**绘制（页底 / 描边 / 文字取自预设调色板），
/// 选择前后文字均保持可读，也直观预览换肤效果；
/// 选中态用当前主题主色描边 + 对勾，交互语言与全站一致。
class ThemePresetPicker extends StatelessWidget {
  const ThemePresetPicker({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final AppThemePreset selected;
  final ValueChanged<AppThemePreset> onSelected;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: tokens.spaceSm,
      runSpacing: tokens.spaceSm,
      children: [
        for (final preset in AppThemePreset.values)
          _PresetCard(
            preset: preset,
            selected: preset == selected,
            checkColor: scheme.primary,
            onTap: () => onSelected(preset),
          ),
      ],
    );
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.preset,
    required this.selected,
    required this.checkColor,
    required this.onTap,
  });

  final AppThemePreset preset;
  final bool selected;
  final Color checkColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final p = preset.palette;
    return Material(
      color: p.page,
      borderRadius: BorderRadius.circular(tokens.radiusMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(tokens.radiusMd),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 156,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(tokens.radiusMd),
            border: Border.all(
              color: selected ? checkColor : p.hairline,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              // 品牌点缀渐变小色块，一眼看出主题气质
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [p.accentTop, p.accentBottom],
                  ),
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '主题${preset.id}',
                      style: TextStyle(
                        fontSize: 10,
                        height: 1.3,
                        color: p.inkWeak,
                      ),
                    ),
                    Text(
                      preset.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.3,
                        fontWeight: FontWeight.w700,
                        color: p.ink,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 4),
                Icon(Icons.check_circle_rounded, size: 18, color: checkColor),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
