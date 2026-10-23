import 'package:flutter/material.dart';

import '../../core/api/key_value_store.dart';

/// 主题模式状态：跟随系统 / 浅色 / 深色（PRD §5.6.4 设置项）。
///
/// M1 只做「切换 + 持久化」；M6 儿童模式接入后按
/// 「儿童主题 > 用户浅/深色设置」的优先级覆盖 [mode]。
class ThemeController extends ChangeNotifier {
  ThemeController(this._kv);

  static const String prefKey = 'theme_mode';

  final KeyValueStore _kv;

  ThemeMode _mode = ThemeMode.system;
  bool _loaded = false;

  ThemeMode get mode => _mode;

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
    _loaded = true;
    notifyListeners();
  }

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
