import 'package:flutter/material.dart';

/// 调色板 —— 全项目唯一允许出现色值的地方（widget 内禁止硬编码颜色，见 M1 约束）。
///
/// 六个主题皮肤（`docs/theme.md` 主题 1、3~7；主题2 已移除，id 2 保留空位）：主题色只换**颜色**，
/// 圆角/间距/字阶等结构 token 全主题共用（见 `app_tokens.dart`），
/// 保证配色、字体、间距、组件样式在各页面/状态间一致。
///
/// 每套 [ThemePalette] 的文字与「底色上的文字」均按 WCAG AA（≥4.5:1）校验，
/// 由 `test/theme_contrast_test.dart` 断言守卫；亮色/深色主题均可读。
enum AppThemePreset {
  warmPaper(1, '暖纸书卷'),
  darkGold(3, '暗夜金橙'),
  springPromo(4, '春日活力'),
  mintSpring(5, '薄荷春芽'),
  inkNight(6, '静夜墨灰'),
  mochaNight(7, '暖夜摩卡');

  const AppThemePreset(this.id, this.label);

  /// 预设序号（持久化用，勿改）
  final int id;

  /// 短名（选择器用）
  final String label;

  /// 完整名（如「主题1 · 暖纸书卷」）
  String get title => '主题$id · $label';

  /// 主题3/6/7 为深色预设
  bool get isDark =>
      this == AppThemePreset.darkGold ||
      this == AppThemePreset.inkNight ||
      this == AppThemePreset.mochaNight;

  /// 自检卡片按顺序循环
  AppThemePreset get next => values[(index + 1) % values.length];

  ThemePalette get palette => switch (this) {
        AppThemePreset.warmPaper => ThemePalette.warmPaper,
        AppThemePreset.darkGold => ThemePalette.darkGold,
        AppThemePreset.springPromo => ThemePalette.springPromo,
        AppThemePreset.mintSpring => ThemePalette.mintSpring,
        AppThemePreset.inkNight => ThemePalette.inkNight,
        AppThemePreset.mochaNight => ThemePalette.mochaNight,
      };

  static AppThemePreset? fromId(int? id) {
    for (final p in values) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// 一套完整主题配色（角色化，不暴露具体用途以外的色值）。
///
/// 角色约束（由对比度测试守卫）：
/// - `ink` / `inkSoft` / `inkWeak` 在 `page` 与卡片底上 ≥4.5:1；
/// - `onPrimary` 在 `primary` 上、`onSecondary` 在 `secondary` 上 ≥4.5:1；
/// - `onAccent` 在 `accentTop`/`accentBottom` 上 ≥4.5:1；
/// - `primary` / `secondary` / `error` 作为文字出现在 `page` 上 ≥4.5:1。
class ThemePalette {
  const ThemePalette({
    required this.isDark,
    required this.page,
    required this.cardTop,
    required this.cardBottom,
    required this.hairline,
    required this.ink,
    required this.inkSoft,
    required this.inkWeak,
    required this.primary,
    required this.onPrimary,
    required this.secondary,
    required this.onSecondary,
    required this.accentTop,
    required this.accentBottom,
    required this.onAccent,
    required this.error,
    required this.onError,
  });

  final bool isDark;

  // 背景层
  final Color page; // 页面背景
  final Color cardTop; // 卡片亮面（微渐变起）
  final Color cardBottom; // 卡片暗面（微渐变止）
  final Color hairline; // 分隔细线/描边

  // 文字层（主 / 次 / 弱）
  final Color ink;
  final Color inkSoft;
  final Color inkWeak;

  // 行为层（实心底 + 其上的文字）
  final Color primary;
  final Color onPrimary;
  final Color secondary;
  final Color onSecondary;

  // 品牌点缀（渐变填充 + 其上的文字，如「可」字 Logo 徽标）
  final Color accentTop;
  final Color accentBottom;
  final Color onAccent;

  // 语义
  final Color error;
  final Color onError;

  // ── 主题1：暖纸书卷（Warm Paper / Vintage Book）────────────────────
  // 暖奶油纸感、低饱和、琥珀点缀；文字比 theme.md 参考值加深以满足 AA。
  static const ThemePalette warmPaper = ThemePalette(
    isDark: false,
    page: Color(0xFFF7F1E7), // 奶油米白
    cardTop: Color(0xFFFBF7EF),
    cardBottom: Color(0xFFF3E9D8),
    hairline: Color(0xFFE6DBC7),
    ink: Color(0xFF3D362C), // 深棕炭
    inkSoft: Color(0xFF5B5344),
    inkWeak: Color(0xFF6B6252),
    primary: Color(0xFF8A5D14), // 深琥珀（可作文字/白字按钮底）
    onPrimary: Color(0xFFFFFFFF),
    secondary: Color(0xFF3F6B4E), // 辅助绿
    onSecondary: Color(0xFFFFFFFF),
    accentTop: Color(0xFFE8B04B), // 琥珀金渐变
    accentBottom: Color(0xFFD98E28),
    onAccent: Color(0xFF2E2109),
    error: Color(0xFFC62B1F),
    onError: Color(0xFFFFFFFF),
  );

  // ── 主题3：暗夜金橙·国潮（Dark & Gold）───────────────────────────
  // 深色主题（主题3）：炭黑底 + 深灰卡片，橙金强调，暖白文字。
  static const ThemePalette darkGold = ThemePalette(
    isDark: true,
    page: Color(0xFF141414), // 炭黑
    cardTop: Color(0xFF242424), // 深灰黑
    cardBottom: Color(0xFF1C1C1C),
    hairline: Color(0xFF333333),
    ink: Color(0xFFF5EFE6), // 暖白
    inkSoft: Color(0xFFCFC7BB),
    inkWeak: Color(0xFF9A938A),
    primary: Color(0xFFFF9A2E), // 橙金
    onPrimary: Color(0xFF241503),
    secondary: Color(0xFFE8C46A), // 贵气金
    onSecondary: Color(0xFF241503),
    accentTop: Color(0xFFFF9A2E), // 橙金 → 金渐变
    accentBottom: Color(0xFFE8C46A),
    onAccent: Color(0xFF241503),
    error: Color(0xFFFF6B5E), // 深底上的警示红（提亮保可读）
    onError: Color(0xFF2A0F0C),
  );

  // ── 主题4：明橙新绿·春日活力（Bright Orange-Green）─────────────────
  // 暖白底 + 橙红主行动 + 新绿辅助 + 金黄渐变点缀（儿童模式默认主题）。
  static const ThemePalette springPromo = ThemePalette(
    isDark: false,
    page: Color(0xFFFAFAF7), // 暖白
    cardTop: Color(0xFFFFFFFF),
    cardBottom: Color(0xFFF5F5F0),
    hairline: Color(0xFFE6E4DA),
    ink: Color(0xFF1F1F1F), // 近黑
    inkSoft: Color(0xFF555555),
    inkWeak: Color(0xFF676767),
    primary: Color(0xFFC43A0B), // 橙红（收深，可作文字/白字按钮底）
    onPrimary: Color(0xFFFFFFFF),
    secondary: Color(0xFF2E7D32), // 辅助绿
    onSecondary: Color(0xFFFFFFFF),
    accentTop: Color(0xFFFFC107), // 金黄渐变
    accentBottom: Color(0xFFFF9800),
    onAccent: Color(0xFF3D2A00),
    error: Color(0xFFB3261E),
    onError: Color(0xFFFFFFFF),
  );

  // ── 主题5：薄荷春芽·清新教育（Mint Spring）────────────────────────
  // 薄荷浅底 + 纯白卡片，墨绿标题，樱花粉点缀（收深成文字可用的玫红）。
  static const ThemePalette mintSpring = ThemePalette(
    isDark: false,
    page: Color(0xFFE8F5EA), // 薄荷浅底
    cardTop: Color(0xFFFFFFFF),
    cardBottom: Color(0xFFF3FAF4),
    hairline: Color(0xFFD5EBD9),
    ink: Color(0xFF1B5E4B), // 墨绿
    inkSoft: Color(0xFF35655A),
    inkWeak: Color(0xFF4E6B5E),
    primary: Color(0xFF1F7A63), // 深青绿
    onPrimary: Color(0xFFFFFFFF),
    secondary: Color(0xFFA84865), // 樱粉（收深成文字可用的玫红）
    onSecondary: Color(0xFFFFFFFF),
    accentTop: Color(0xFFCDE9C8), // 薄荷绿渐变
    accentBottom: Color(0xFF9FD4A6),
    onAccent: Color(0xFF14523F),
    error: Color(0xFFB3261E),
    onError: Color(0xFFFFFFFF),
  );

  // ── 主题6：静夜墨灰·极简夜用（Graphite Night）────────────────────
  // 石墨深灰近单色，纯靠明度分层；雾感鼠尾草绿 + 藕粉微点缀，克制安静。
  static const ThemePalette inkNight = ThemePalette(
    isDark: true,
    page: Color(0xFF2F3133), // 石墨深灰
    cardTop: Color(0xFF3D4043), // 中性灰面板
    cardBottom: Color(0xFF36393B),
    hairline: Color(0xFF4C5053),
    ink: Color(0xFFF1F3F4), // 冷白
    inkSoft: Color(0xFFC3C8CB),
    inkWeak: Color(0xFFABB2B6),
    primary: Color(0xFF8FBFA3), // 雾感鼠尾草绿
    onPrimary: Color(0xFF14261C),
    secondary: Color(0xFFD6A3AC), // 藕粉
    onSecondary: Color(0xFF2B1518),
    accentTop: Color(0xFFA8D0B8), // 鼠尾草绿渐变
    accentBottom: Color(0xFF7FAE93),
    onAccent: Color(0xFF14261C),
    error: Color(0xFFFF8C82), // 深底上的珊瑚红（提亮保可读）
    onError: Color(0xFF2A0F0C),
  );

  // ── 主题7：暖夜摩卡·可可夜读（Mocha Night）───────────────────────
  // 深可可棕暖黑，奶油暖白文字，焦糖琥珀渐变点缀，夜读陪伴感。
  static const ThemePalette mochaNight = ThemePalette(
    isDark: true,
    page: Color(0xFF3A2B23), // 深可可棕
    cardTop: Color(0xFF4B3A30), // 暖棕面板
    cardBottom: Color(0xFF43322A),
    hairline: Color(0xFF5D493D),
    ink: Color(0xFFF7EADC), // 奶油暖白
    inkSoft: Color(0xFFDCC7B4),
    inkWeak: Color(0xFFC4A78F),
    primary: Color(0xFFE8A35C), // 焦糖琥珀
    onPrimary: Color(0xFF2B1A0E),
    secondary: Color(0xFFE59A8C), // 陶土玫瑰
    onSecondary: Color(0xFF2B120E),
    accentTop: Color(0xFFF0B06A), // 琥珀金渐变
    accentBottom: Color(0xFFC97F3D),
    onAccent: Color(0xFF2B1A0E),
    error: Color(0xFFFF8A7A), // 深底上的暖珊瑚（提亮保可读）
    onError: Color(0xFF2A0F0C),
  );
}
