import 'package:flutter/material.dart';

import 'app_palette.dart';

/// 主题 token（ThemeExtension）：圆角、间距、渐变、发丝线、字阶。
///
/// M1 约束「禁止硬编码颜色」的落地方式：
/// 颜色一律取 `Theme.of(context).colorScheme` / `cardColor` 等标准槽位，
/// 这里补齐 Material 没有的**结构性 token**（圆角/间距/渐变/字阶），
/// M6 儿童模式只需要换一套 [AppTokens] + [ColorScheme]，页面不用动。
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.radiusSm,
    required this.radiusMd,
    required this.radiusLg,
    required this.radiusPill,
    required this.spaceXs,
    required this.spaceSm,
    required this.spaceMd,
    required this.spaceLg,
    required this.cardGradient,
    required this.accentGradient,
    required this.hairlineColor,
    required this.onHairline,
    required this.displayStyle,
    required this.titleStyle,
    required this.sectionStyle,
    required this.bodyStyle,
    required this.captionStyle,
    required this.numStyle,
  });

  // 圆角
  final double radiusSm;
  final double radiusMd;
  final double radiusLg;
  final double radiusPill;

  // 间距（4 基准）
  final double spaceXs;
  final double spaceSm;
  final double spaceMd;
  final double spaceLg;

  // 渐变
  final Gradient cardGradient; // 卡片微渐变
  final Gradient accentGradient; // 主行动（琥珀）

  final Color hairlineColor;
  final Color onHairline;

  // 字阶
  final TextStyle displayStyle;
  final TextStyle titleStyle;
  final TextStyle sectionStyle;
  final TextStyle bodyStyle;
  final TextStyle captionStyle;
  final TextStyle numStyle;

  /// 浅色：暖纸书卷
  factory AppTokens.light() => AppTokens(
        radiusSm: 8,
        radiusMd: 14,
        radiusLg: 20,
        radiusPill: 999,
        spaceXs: 4,
        spaceSm: 8,
        spaceMd: 16,
        spaceLg: 24,
        cardGradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppPalette.paperCard, AppPalette.paperCardDeep],
          stops: [0.0, 1.0],
        ),
        accentGradient: const LinearGradient(
          colors: [AppPalette.amber, AppPalette.amberDeep],
        ),
        hairlineColor: AppPalette.paperHairline,
        onHairline: AppPalette.warmGrey,
        displayStyle: const TextStyle(
          fontSize: 28,
          height: 1.2,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
          color: AppPalette.ink,
        ),
        titleStyle: const TextStyle(
          fontSize: 20,
          height: 1.3,
          fontWeight: FontWeight.w700,
          color: AppPalette.ink,
        ),
        sectionStyle: const TextStyle(
          fontSize: 15,
          height: 1.4,
          fontWeight: FontWeight.w700,
          color: AppPalette.ink,
        ),
        bodyStyle: const TextStyle(
          fontSize: 14,
          height: 1.55,
          color: AppPalette.inkSoft,
        ),
        captionStyle: const TextStyle(
          fontSize: 12,
          height: 1.4,
          color: AppPalette.warmGrey,
        ),
        numStyle: const TextStyle(
          fontSize: 13,
          height: 1.3,
          fontWeight: FontWeight.w600,
          color: AppPalette.inkSoft,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      );

  /// 深色：暗夜金橙
  factory AppTokens.dark() => AppTokens(
        radiusSm: 8,
        radiusMd: 14,
        radiusLg: 20,
        radiusPill: 999,
        spaceXs: 4,
        spaceSm: 8,
        spaceMd: 16,
        spaceLg: 24,
        cardGradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppPalette.nightCard, AppPalette.nightCardDeep],
        ),
        accentGradient: const LinearGradient(
          colors: [AppPalette.orange, AppPalette.goldDeep],
        ),
        hairlineColor: AppPalette.nightHairline,
        onHairline: AppPalette.nightWarmGrey,
        displayStyle: const TextStyle(
          fontSize: 28,
          height: 1.2,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
          color: AppPalette.nightInk,
        ),
        titleStyle: const TextStyle(
          fontSize: 20,
          height: 1.3,
          fontWeight: FontWeight.w700,
          color: AppPalette.nightInk,
        ),
        sectionStyle: const TextStyle(
          fontSize: 15,
          height: 1.4,
          fontWeight: FontWeight.w700,
          color: AppPalette.nightInk,
        ),
        bodyStyle: const TextStyle(
          fontSize: 14,
          height: 1.55,
          color: AppPalette.nightInkSoft,
        ),
        captionStyle: const TextStyle(
          fontSize: 12,
          height: 1.4,
          color: AppPalette.nightWarmGrey,
        ),
        numStyle: const TextStyle(
          fontSize: 13,
          height: 1.3,
          fontWeight: FontWeight.w600,
          color: AppPalette.nightInkSoft,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      );

  /// 儿童：薄荷春芽（M6 儿童模式）—— 高饱和低刺激、大圆角卡片、
  /// 字号整体 +1、间距放宽（PRD §5.5「大图标、插画风」）。
  factory AppTokens.children() => AppTokens(
        radiusSm: 12,
        radiusMd: 18,
        radiusLg: 24,
        radiusPill: 999,
        spaceXs: 4,
        spaceSm: 10,
        spaceMd: 18,
        spaceLg: 26,
        cardGradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppPalette.kidCard, AppPalette.kidCardDeep],
          stops: [0.0, 1.0],
        ),
        accentGradient: const LinearGradient(
          colors: [AppPalette.mintMid, AppPalette.kidGreen],
        ),
        hairlineColor: AppPalette.kidHairline,
        onHairline: AppPalette.kidGrey,
        displayStyle: const TextStyle(
          fontSize: 30,
          height: 1.2,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
          color: AppPalette.kidInk,
        ),
        titleStyle: const TextStyle(
          fontSize: 21,
          height: 1.3,
          fontWeight: FontWeight.w700,
          color: AppPalette.kidInk,
        ),
        sectionStyle: const TextStyle(
          fontSize: 16,
          height: 1.4,
          fontWeight: FontWeight.w700,
          color: AppPalette.kidInk,
        ),
        bodyStyle: const TextStyle(
          fontSize: 15,
          height: 1.55,
          color: AppPalette.kidInkSoft,
        ),
        captionStyle: const TextStyle(
          fontSize: 13,
          height: 1.4,
          color: AppPalette.kidGrey,
        ),
        numStyle: const TextStyle(
          fontSize: 14,
          height: 1.3,
          fontWeight: FontWeight.w600,
          color: AppPalette.kidInkSoft,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      );

  static AppTokens of(BuildContext context) =>
      Theme.of(context).extension<AppTokens>() ?? AppTokens.light();

  @override
  AppTokens copyWith({
    double? radiusSm,
    double? radiusMd,
    double? radiusLg,
    double? radiusPill,
    double? spaceXs,
    double? spaceSm,
    double? spaceMd,
    double? spaceLg,
    Gradient? cardGradient,
    Gradient? accentGradient,
    Color? hairlineColor,
    Color? onHairline,
    TextStyle? displayStyle,
    TextStyle? titleStyle,
    TextStyle? sectionStyle,
    TextStyle? bodyStyle,
    TextStyle? captionStyle,
    TextStyle? numStyle,
  }) =>
      AppTokens(
        radiusSm: radiusSm ?? this.radiusSm,
        radiusMd: radiusMd ?? this.radiusMd,
        radiusLg: radiusLg ?? this.radiusLg,
        radiusPill: radiusPill ?? this.radiusPill,
        spaceXs: spaceXs ?? this.spaceXs,
        spaceSm: spaceSm ?? this.spaceSm,
        spaceMd: spaceMd ?? this.spaceMd,
        spaceLg: spaceLg ?? this.spaceLg,
        cardGradient: cardGradient ?? this.cardGradient,
        accentGradient: accentGradient ?? this.accentGradient,
        hairlineColor: hairlineColor ?? this.hairlineColor,
        onHairline: onHairline ?? this.onHairline,
        displayStyle: displayStyle ?? this.displayStyle,
        titleStyle: titleStyle ?? this.titleStyle,
        sectionStyle: sectionStyle ?? this.sectionStyle,
        bodyStyle: bodyStyle ?? this.bodyStyle,
        captionStyle: captionStyle ?? this.captionStyle,
        numStyle: numStyle ?? this.numStyle,
      );

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) {
    if (other is! AppTokens) return this;
    return AppTokens(
      radiusSm: radiusSm,
      radiusMd: radiusMd,
      radiusLg: radiusLg,
      radiusPill: radiusPill,
      spaceXs: spaceXs,
      spaceSm: spaceSm,
      spaceMd: spaceMd,
      spaceLg: spaceLg,
      cardGradient: Gradient.lerp(cardGradient, other.cardGradient, t)!,
      accentGradient:
          Gradient.lerp(accentGradient, other.accentGradient, t)!,
      hairlineColor: Color.lerp(hairlineColor, other.hairlineColor, t)!,
      onHairline: Color.lerp(onHairline, other.onHairline, t)!,
      displayStyle: TextStyle.lerp(displayStyle, other.displayStyle, t)!,
      titleStyle: TextStyle.lerp(titleStyle, other.titleStyle, t)!,
      sectionStyle: TextStyle.lerp(sectionStyle, other.sectionStyle, t)!,
      bodyStyle: TextStyle.lerp(bodyStyle, other.bodyStyle, t)!,
      captionStyle: TextStyle.lerp(captionStyle, other.captionStyle, t)!,
      numStyle: TextStyle.lerp(numStyle, other.numStyle, t)!,
    );
  }
}
