import 'package:flutter/material.dart';

import '../../core/api/key_value_store.dart';
import 'app_palette.dart';

/// 主题皮肤状态：六个自定义预设（`docs/theme.md` 主题 1、3~7，主题2 已移除）。
///
/// 只有**一个**主题槽位，用户可在设置页/自检卡片自由切换任意主题，
/// 六套预设都是完整皮肤（含深色的主题3/6/7），切换即换肤（无重启）。
///
/// 与儿童模式（M6）的关系（PRD §5.5 + 用户需求）：
/// - 不区分「一般/儿童」两套主题，儿童模式不锁定主题；
/// - **进入儿童模式的那一刻自动切换到主题4「春日活力」**（儿童默认皮肤），
///   之后用户仍可手动切到任意其他主题；
/// - 退出儿童模式不做强制换肤，保持当前主题。
///
/// 旧「跟随系统 / 浅色 / 深色」设置仅做一次性迁移（深色 → 主题3），
/// 不再对外暴露 ThemeMode。
class ThemeController extends ChangeNotifier {
  ThemeController(this._kv);

  /// 当前主题（存预设 id，如 '1'）。默认主题1「暖纸书卷」。
  static const String presetKey = 'theme_preset';

  /// 旧「浅色/深色/跟随系统」key，仅迁移读取。
  static const String legacyModeKey = 'theme_mode';

  /// 儿童模式开关 key。
  static const String childrenKey = 'children_mode';

  /// 进入儿童模式时自动应用的主题（儿童默认皮肤）。
  static const AppThemePreset childrenDefaultPreset = AppThemePreset.springPromo;

  final KeyValueStore _kv;

  AppThemePreset _preset = AppThemePreset.warmPaper;
  bool _children = false;
  bool _loaded = false;

  /// 当前主题（默认主题1）。可自由切换任意预设。
  AppThemePreset get preset => _preset;

  /// 儿童模式开关（M6）：主题皮肤 + 白名单内容过滤，不做操作限制。
  bool get children => _children;

  bool get loaded => _loaded;

  /// 标签文案（设置页 / 自检卡片共用）。
  static String labelOf(AppThemePreset preset) => preset.title;

  Future<void> load() async {
    _preset = _readPreset(presetKey, migrateLegacy: true);
    _children = _kv.getString(childrenKey) == '1';
    _loaded = true;
    notifyListeners();
  }

  /// 读预设 id；无值时回退默认主题1。
  /// [migrateLegacy] 时兼容旧「浅色/深色」设置：深色 → 主题3 暗夜金橙。
  AppThemePreset _readPreset(String key, {bool migrateLegacy = false}) {
    final id = int.tryParse(_kv.getString(key) ?? '');
    final preset = AppThemePreset.fromId(id);
    if (preset != null) return preset;
    if (migrateLegacy && _kv.getString(legacyModeKey) == 'dark') {
      return AppThemePreset.darkGold;
    }
    return AppThemePreset.warmPaper;
  }

  /// 切换主题（任意预设，无模式限制）。
  Future<void> setPreset(AppThemePreset value) async {
    if (value == _preset) return;
    _preset = value;
    notifyListeners();
    await _kv.setString(presetKey, value.id.toString());
  }

  /// 切换儿童模式（M6：关闭时由 UI 先走二次确认弹层，再调这里）。
  /// 进入时自动切到儿童默认主题4「春日活力」（之后仍可手动改其他主题）。
  Future<void> setChildren(bool value) async {
    if (value == _children) return;
    _children = value;
    notifyListeners();
    await _kv.setString(childrenKey, value ? '1' : '0');
    if (value) {
      // 进入儿童模式：自动套用儿童默认皮肤（主题4），不锁定、可手动切换。
      await setPreset(childrenDefaultPreset);
    }
  }

  /// 切换儿童模式（同 [setChildren]，测试/自检用）。
  Future<void> toggleChildren() => setChildren(!_children);

  /// 自检卡片里按顺序循环切换主题。
  Future<void> cycle() => setPreset(_preset.next);
}
