import 'package:flutter/material.dart';

/// 调色板 —— 唯一允许出现色值的地方（widget 内禁止硬编码颜色，见 M1 约束）。
///
/// 浅色 = `docs/theme.md` 主题 1「暖纸书卷」，
/// 深色 = 主题 3「暗夜金橙·国潮」，
/// 儿童 = 主题 5「薄荷春芽」（M6 儿童模式接入，此处先给 token）。
class AppPalette {
  AppPalette._();

  // ── 浅色：暖纸书卷 ────────────────────────────────────────────────
  static const Color paper = Color(0xFFF7F1E7); // 奶油米白 页面背景
  static const Color paperCard = Color(0xFFFFFCF6); // 卡片亮面
  static const Color paperCardDeep = Color(0xFFF3E9D8); // 卡片暗面（微渐变）
  static const Color paperHairline = Color(0xFFE6DBC7); // 分隔细线
  static const Color ink = Color(0xFF3D362C); // 深棕炭 主文字
  static const Color inkSoft = Color(0xFF6B6252); // 次级文字
  static const Color warmGrey = Color(0xFFA39A88); // 弱化文字
  static const Color amber = Color(0xFFE8B04B); // 琥珀金 起
  static const Color amberDeep = Color(0xFFD98E28); // 琥珀金 止（可读文字色）
  static const Color black = Color(0xFF14110D); // 纯黑播放锚点
  static const Color jade = Color(0xFF4E7A5C); // 辅助绿（进度/成功）

  // ── 深色：暗夜金橙 ────────────────────────────────────────────────
  static const Color night = Color(0xFF141414); // 页面背景 炭黑
  static const Color nightCard = Color(0xFF242424); // 卡片 深灰黑
  static const Color nightCardDeep = Color(0xFF1C1C1C); // 卡片暗面
  static const Color nightHairline = Color(0xFF333333); // 细线
  static const Color nightInk = Color(0xFFF5EFE6); // 暖白 主文字
  static const Color nightInkSoft = Color(0xFFCFC7BB); // 次级文字
  static const Color nightWarmGrey = Color(0xFF9A938A); // 弱化文字
  static const Color orange = Color(0xFFFF9A2E); // 橙金 强调
  static const Color gold = Color(0xFFE8C46A); // 贵气金 渐变亮部
  static const Color goldDeep = Color(0xFFC9962A); // 金 渐变暗部
  static const Color alertRed = Color(0xFFE63B2E); // 警示红

  // ── 儿童：薄荷春芽（M6 用，先占位保证 token 齐全） ────────────────
  static const Color mintLight = Color(0xFFCDE9C8);
  static const Color mintMid = Color(0xFF9FD4A6);
  static const Color kidInk = Color(0xFF1B5E4B);
  static const Color kidPink = Color(0xFFF8BBD0);
}
