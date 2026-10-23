import 'package:shared_preferences/shared_preferences.dart';

import 'key_value_store.dart';

/// `SharedPreferences` 实现的 [KeyValueStore]（R2：所有本地数据只存本地）。
class PrefsKeyValueStore implements KeyValueStore {
  PrefsKeyValueStore._(this._prefs);

  final SharedPreferences _prefs;

  static Future<PrefsKeyValueStore> open() async =>
      PrefsKeyValueStore._(await SharedPreferences.getInstance());

  @override
  String? getString(String key) => _prefs.getString(key);

  @override
  Future<void> setString(String key, String value) =>
      _prefs.setString(key, value);

  @override
  Future<void> remove(String key) => _prefs.remove(key);
}
