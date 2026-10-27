import 'package:flutter/material.dart';

import 'app_palette.dart';

/// 主题 token（ThemeExtension）：圆角、间距、渐变、发丝线、字阶。
///
/// M1 约束「禁止硬编码颜色」的落地方式：
/// 颜色一律取 `Theme.of(context).colorScheme` / [AppTokens] 的角色槽位，
/// 这里补齐 Material 没有的**结构性 token**（圆角/间距/渐变/字阶）。
///
/// 一致性约束：五个主题皮肤只换颜色（[ThemePalette]），
/// 本类的圆角/间距/字阶**全主题共用同一套**——字体、字号、行高、间距、
/// 组件形状在各页面与各状态之间保持统一。
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
    required this.onAccent,
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
  final Gradient accentGradient; // 品牌点缀（Logo 徽标 / 分区竖条）

  final Color hairlineColor;
  final Color onHairline;

  /// 品牌点缀渐变上的文字色（如「可」字徽标）。
  final Color onAccent;

  // 字阶
  final TextStyle displayStyle;
  final TextStyle titleStyle;
  final TextStyle sectionStyle;
  final TextStyle bodyStyle;
  final TextStyle captionStyle;
  final TextStyle numStyle;

  /// 由一套 [ThemePalette] 构建全主题共用的结构 token。
  factory AppTokens.ofPalette(ThemePalette p) => AppTokens(
        radiusSm: 8,
        radiusMd: 14,
        radiusLg: 20,
        radiusPill: 999,
        spaceXs: 4,
        spaceSm: 8,
        spaceMd: 16,
        spaceLg: 24,
        cardGradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [p.cardTop, p.cardBottom],
          stops: const [0.0, 1.0],
        ),
        accentGradient: LinearGradient(
          colors: [p.accentTop, p.accentBottom],
        ),
        hairlineColor: p.hairline,
        onHairline: p.inkWeak,
        onAccent: p.onAccent,
        displayStyle: TextStyle(
          fontSize: 28,
          height: 1.2,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
          color: p.ink,
        ),
        titleStyle: TextStyle(
          fontSize: 20,
          height: 1.3,
          fontWeight: FontWeight.w700,
          color: p.ink,
        ),
        sectionStyle: TextStyle(
          fontSize: 15,
          height: 1.4,
          fontWeight: FontWeight.w700,
          color: p.ink,
        ),
        bodyStyle: TextStyle(
          fontSize: 14,
          height: 1.55,
          color: p.inkSoft,
        ),
        captionStyle: TextStyle(
          fontSize: 12,
          height: 1.4,
          color: p.inkWeak,
        ),
        numStyle: TextStyle(
          fontSize: 13,
          height: 1.3,
          fontWeight: FontWeight.w600,
          color: p.inkSoft,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      );

  static AppTokens of(BuildContext context) =>
      Theme.of(context).extension<AppTokens>() ??
      AppTokens.ofPalette(ThemePalette.warmPaper);

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
    Color? onAccent,
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
        onAccent: onAccent ?? this.onAccent,
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
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      displayStyle: TextStyle.lerp(displayStyle, other.displayStyle, t)!,
      titleStyle: TextStyle.lerp(titleStyle, other.titleStyle, t)!,
      sectionStyle: TextStyle.lerp(sectionStyle, other.sectionStyle, t)!,
      bodyStyle: TextStyle.lerp(bodyStyle, other.bodyStyle, t)!,
      captionStyle: TextStyle.lerp(captionStyle, other.captionStyle, t)!,
      numStyle: TextStyle.lerp(numStyle, other.numStyle, t)!,
    );
  }
}
