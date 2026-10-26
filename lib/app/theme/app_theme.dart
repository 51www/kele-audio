import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'app_tokens.dart';

/// 全局主题：浅色（暖纸书卷）/ 深色（暗夜金橙）/ 儿童（薄荷春芽）。
///
/// 主题优先级：**儿童主题 > 用户浅/深色设置**（PRD §5.5）——
/// 儿童模式开启时整个 App 固定用 [children]，不看用户的深色设置。
class AppTheme {
  AppTheme._();

  static ThemeData get light => build(Brightness.light);
  static ThemeData get dark => build(Brightness.dark);

  /// 儿童主题（M6）：薄荷春芽，固定浅色底。
  static ThemeData get children => _build(
        brightness: Brightness.light,
        tokens: AppTokens.children(),
        scheme: const ColorScheme.light().copyWith(
          primary: AppPalette.kidTeal,
          onPrimary: Colors.white,
          secondary: AppPalette.kidGreen,
          onSecondary: Colors.white,
          surface: AppPalette.kidPage,
          onSurface: AppPalette.kidInk,
          onSurfaceVariant: AppPalette.kidInkSoft,
          outline: AppPalette.kidHairline,
          outlineVariant: AppPalette.kidHairline,
          surfaceContainer: AppPalette.kidCard,
          error: AppPalette.alertRed,
        ),
      );

  static ThemeData build(Brightness brightness) {
    final isLight = brightness == Brightness.light;
    final tokens = isLight ? AppTokens.light() : AppTokens.dark();

    final scheme = ColorScheme.fromSeed(
      seedColor: isLight ? AppPalette.amberDeep : AppPalette.orange,
      brightness: brightness,
    ).copyWith(
      primary: isLight ? AppPalette.amberDeep : AppPalette.orange,
      onPrimary: isLight ? Colors.white : AppPalette.black,
      secondary: isLight ? AppPalette.jade : AppPalette.gold,
      onSecondary: isLight ? Colors.white : AppPalette.black,
      surface: isLight ? AppPalette.paper : AppPalette.night,
      onSurface: isLight ? AppPalette.ink : AppPalette.nightInk,
      onSurfaceVariant:
          isLight ? AppPalette.warmGrey : AppPalette.nightWarmGrey,
      outline: isLight ? AppPalette.paperHairline : AppPalette.nightHairline,
      outlineVariant:
          isLight ? AppPalette.paperHairline : AppPalette.nightHairline,
      surfaceContainer:
          isLight ? AppPalette.paperCard : AppPalette.nightCard,
      error: isLight ? AppPalette.alertRed : AppPalette.alertRed,
    );

    return _build(brightness: brightness, tokens: tokens, scheme: scheme);
  }

  static ThemeData _build({
    required Brightness brightness,
    required AppTokens tokens,
    required ColorScheme scheme,
  }) {
    final isLight = brightness == Brightness.light;

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
      cardColor: isLight ? AppPalette.paperCard : AppPalette.nightCard,
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
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainer,
        selectedColor: scheme.primary,
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
        backgroundColor: isLight ? AppPalette.black : AppPalette.nightInk,
        contentTextStyle: tokens.bodyStyle.copyWith(
          color: isLight ? AppPalette.paper : AppPalette.night,
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
