import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:kele_audio/app/theme/app_palette.dart';

/// 主题可读性守卫：五套皮肤的文字/底色组合按 WCAG AA（≥4.5:1）断言。
///
/// 覆盖：主/次/弱文字 × 页面/卡片底、按钮文字 × 按钮底、
/// 渐变点缀上的文字 × 渐变两端、主色/警示色作文字 × 页面/卡片底。
void main() {
  double ratio(Color fg, Color bg) {
    final l1 = fg.computeLuminance();
    final l2 = bg.computeLuminance();
    final (hi, lo) = l1 >= l2 ? (l1, l2) : (l2, l1);
    return (hi + 0.05) / (lo + 0.05);
  }

  void expectReadable(
    AppThemePreset preset,
    String role,
    Color fg,
    Color bg,
    String bgName,
  ) {
    final r = ratio(fg, bg);
    expect(
      r,
      greaterThanOrEqualTo(4.5),
      reason: '${preset.title}：$role 在 $bgName 上对比度 ${r.toStringAsFixed(2)}，'
          '低于 AA 标准 4.5',
    );
  }

  group('五套主题文字对比度（WCAG AA）', () {
    for (final preset in AppThemePreset.values) {
      test('${preset.title} 文字与底色全部可读', () {
        final p = preset.palette;
        final backgrounds = {
          '页面底': p.page,
          '卡片亮面': p.cardTop,
          '卡片暗面': p.cardBottom,
        };

        backgrounds.forEach((name, bg) {
          expectReadable(preset, '主文字 ink', p.ink, bg, name);
          expectReadable(preset, '次文字 inkSoft', p.inkSoft, bg, name);
          expectReadable(preset, '弱文字 inkWeak', p.inkWeak, bg, name);
          expectReadable(preset, '主色 primary（文字用）', p.primary, bg, name);
          expectReadable(preset, '警示色 error', p.error, bg, name);
        });

        // 实心按钮 / 选中态：底色上的文字
        expectReadable(preset, 'onPrimary', p.onPrimary, p.primary, '主色底');
        expectReadable(
          preset, 'onSecondary', p.onSecondary, p.secondary, '辅助色底',
        );

        // 品牌点缀渐变（Logo 徽标 / 分区竖条）上的文字，两端都要可读
        expectReadable(
          preset, 'onAccent', p.onAccent, p.accentTop, '渐变起',
        );
        expectReadable(
          preset, 'onAccent', p.onAccent, p.accentBottom, '渐变止',
        );
      });
    }
  });

  group('主题结构不变式', () {
    test('主题3 为深色，其余为亮色；深色主题文字为浅色', () {
      for (final preset in AppThemePreset.values) {
        final p = preset.palette;
        expect(p.isDark, preset == AppThemePreset.darkGold);
        expect(
          p.ink.computeLuminance() > 0.5,
          p.isDark,
          reason: '${preset.title} 文字明度应与底色明度相反',
        );
      }
    });

    test('一般模式默认主题1、儿童模式默认主题4（预设 id 稳定）', () {
      expect(AppThemePreset.warmPaper.id, 1);
      expect(AppThemePreset.springPromo.id, 4);
      expect(AppThemePreset.fromId(1), AppThemePreset.warmPaper);
      expect(AppThemePreset.fromId(4), AppThemePreset.springPromo);
    });
  });
}
