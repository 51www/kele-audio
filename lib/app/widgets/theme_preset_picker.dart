import 'package:flutter/material.dart';

import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';

/// 主题皮肤选择器：六张「色卡」（`docs/theme.md` 主题 1、3~7，主题2 已移除）。
///
/// 每张色卡用**该主题自己的配色**绘制（页底 / 描边 / 文字取自预设调色板），
/// 选择前后文字均保持可读，也直观预览换肤效果；
/// 选中态用当前主题主色描边 + 对勾，交互语言与全站一致。
///
/// 布局：弹性三列（每行 3 张，[Expanded] 横向铺满），单行紧凑色卡。
class ThemePresetPicker extends StatelessWidget {
  const ThemePresetPicker({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final AppThemePreset selected;
  final ValueChanged<AppThemePreset> onSelected;

  static const int _columns = 3;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final presets = AppThemePreset.values;
    return Column(
      children: [
        for (var i = 0; i < presets.length; i += _columns)
          Padding(
            padding: EdgeInsets.only(
              bottom: i + _columns < presets.length ? tokens.spaceSm : 0,
            ),
            child: Row(
              children: [
                for (var j = 0; j < _columns; j++) ...[
                  if (j > 0) SizedBox(width: tokens.spaceSm),
                  Expanded(
                    child: i + j < presets.length
                        ? _PresetCard(
                            preset: presets[i + j],
                            selected: presets[i + j] == selected,
                            checkColor: scheme.primary,
                            onTap: () => onSelected(presets[i + j]),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
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
      borderRadius: BorderRadius.circular(tokens.radiusSm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(tokens.radiusSm),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(tokens.radiusSm),
            border: Border.all(
              color: selected ? checkColor : p.hairline,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              // 品牌点缀渐变小色块，一眼看出主题气质
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [p.accentTop, p.accentBottom],
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    preset.label,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.3,
                      fontWeight: FontWeight.w700,
                      color: p.ink,
                    ),
                  ),
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 2),
                Icon(Icons.check_circle_rounded, size: 15, color: checkColor),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
