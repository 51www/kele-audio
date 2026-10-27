import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'app_tokens.dart';

/// 全局主题：七套自定义皮肤（`docs/theme.md` 主题 1~7）。
///
/// 主题选择：**儿童模式主题 > 一般模式主题**（PRD §5.5）——
/// 一般模式默认主题1「暖纸书卷」，儿童模式默认主题4「春日活力」，
/// 由 [ThemeController] 决定生效预设，这里只负责把预设渲染成 [ThemeData]。
///
/// 一致性约束：七套主题共用同一套结构 token（圆角/间距/字阶），
/// 仅颜色不同；深色预设（主题3/6/7）与亮色预设文字对比度均由测试守卫。
class AppTheme {
  AppTheme._();

  /// 按预设构建主题（唯一入口）。
  static ThemeData of(AppThemePreset preset) {
    final p = preset.palette;
    final brightness = p.isDark ? Brightness.dark : Brightness.light;
    final tokens = AppTokens.ofPalette(p);

    // seed 取主色，派生 Material 标准槽位后整体覆盖为本主题角色色，
    // 保证 Switch/Dialog 等未定制组件也落在同一配色内。
    final scheme = ColorScheme.fromSeed(
      seedColor: p.primary,
      brightness: brightness,
    ).copyWith(
      primary: p.primary,
      onPrimary: p.onPrimary,
      secondary: p.secondary,
      onSecondary: p.onSecondary,
      surface: p.page,
      onSurface: p.ink,
      onSurfaceVariant: p.inkSoft,
      outline: p.hairline,
      outlineVariant: p.hairline,
      surfaceContainer: p.cardTop,
      error: p.error,
      onError: p.onError,
    );

    return _build(brightness: brightness, tokens: tokens, scheme: scheme);
  }

  static ThemeData _build({
    required Brightness brightness,
    required AppTokens tokens,
    required ColorScheme scheme,
  }) {
    final textTheme = ThemeData(brightness: brightness)
        .textTheme
        .apply(
          bodyColor: scheme.onSurface,
          displayColor: scheme.onSurface,
        );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      cardColor: scheme.surfaceContainer,
      dividerColor: tokens.hairlineColor,
      splashFactory: InkSparkle.splashFactory,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: tokens.titleStyle,
        iconTheme: IconThemeData(color: scheme.onSurface),
      ),
      cardTheme: CardThemeData(
        color: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusMd),
          side: BorderSide(color: tokens.hairlineColor),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusLg),
          side: BorderSide(color: tokens.hairlineColor),
        ),
        titleTextStyle: tokens.titleStyle,
        contentTextStyle: tokens.bodyStyle,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainer,
        // 选中态不用实心主色（避免 label 色冲突），用主色淡染 + 主色文字
        selectedColor: scheme.primary.withValues(alpha: 0.14),
        labelStyle: tokens.bodyStyle.copyWith(fontWeight: FontWeight.w600),
        side: BorderSide(color: tokens.hairlineColor),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusPill),
        ),
        showCheckmark: false,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        height: 60,
        indicatorColor: scheme.primary.withValues(alpha: 0.16),
        labelTextStyle: WidgetStatePropertyAll(
          tokens.captionStyle.copyWith(fontWeight: FontWeight.w600),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
            size: 22,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(tokens.radiusPill),
          ),
          textStyle: tokens.bodyStyle.copyWith(
            fontWeight: FontWeight.w700,
            color: scheme.onPrimary,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          side: BorderSide(color: tokens.hairlineColor),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(tokens.radiusPill),
          ),
          textStyle: tokens.bodyStyle.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        // 反相胶囊：与 MiniPlayer 同一语言（深字底浅字 / 浅字底深字）
        backgroundColor: scheme.onSurface,
        contentTextStyle: tokens.bodyStyle.copyWith(
          color: scheme.surfaceContainer,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusMd),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: tokens.hairlineColor,
        thickness: 1,
        space: 1,
      ),
      extensions: [tokens],
    );
  }
}
