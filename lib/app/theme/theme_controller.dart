import 'package:flutter/material.dart';

import '../../core/api/key_value_store.dart';

/// 主题模式状态：跟随系统 / 浅色 / 深色（PRD §5.6.4 设置项）。
///
/// M6 儿童模式接入：[children] 开启时**覆盖** [mode]
///（主题优先级：儿童 > 用户浅/深色，见 [effectiveThemeMode]）。
class ThemeController extends ChangeNotifier {
  ThemeController(this._kv);

  static const String prefKey = 'theme_mode';
  static const String childrenKey = 'children_mode';

  final KeyValueStore _kv;

  ThemeMode _mode = ThemeMode.system;
  bool _children = false;
  bool _loaded = false;

  ThemeMode get mode => _mode;

  /// 儿童模式开关（M6）：主题皮肤 + 白名单内容过滤，不做操作限制。
  bool get children => _children;

  /// 实际生效的主题模式：儿童模式固定浅色（儿童主题只有浅色一套）。
  ThemeMode get effectiveThemeMode =>
      _children ? ThemeMode.light : _mode;

  bool get loaded => _loaded;

  /// 标签文案（设置页 / 自检卡片共用）
  static String labelOf(ThemeMode mode) => switch (mode) {
        ThemeMode.system => '跟随系统',
        ThemeMode.light => '浅色',
        ThemeMode.dark => '深色',
      };

  Future<void> load() async {
    final raw = _kv.getString(prefKey);
    _mode = switch (raw) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    _children = _kv.getString(childrenKey) == '1';
    _loaded = true;
    notifyListeners();
  }

  /// 切换儿童模式（M6：关闭时由 UI 先走二次确认弹层，再调这里）。
  Future<void> setChildren(bool value) async {
    if (value == _children) return;
    _children = value;
    notifyListeners();
    await _kv.setString(childrenKey, value ? '1' : '0');
  }

  /// 切换儿童模式（同 [setChildren]，测试自检用）。
  Future<void> toggleChildren() => setChildren(!_children);

  Future<void> setMode(ThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    await _kv.setString(prefKey, switch (mode) {
      ThemeMode.system => 'system',
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
    });
  }

  /// 自检卡片里按顺序循环切换。
  Future<void> cycle() => setMode(switch (_mode) {
        ThemeMode.system => ThemeMode.light,
        ThemeMode.light => ThemeMode.dark,
        ThemeMode.dark => ThemeMode.system,
      });
}
