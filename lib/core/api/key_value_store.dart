/// 本地键值存取抽象。
///
/// - App 运行时用 `SharedPreferences` 实现（见 `prefs_kv_store.dart`）；
/// - M0 冒烟脚本（`tool/spike/`）与单元测试用 [MemoryKeyValueStore]。
///
/// 这样 `core/api` 保持**纯 Dart**，既能进 Flutter 工程，也能直接 `dart run`。
abstract class KeyValueStore {
  String? getString(String key);

  Future<void> setString(String key, String value);

  Future<void> remove(String key);
}

/// 内存实现：不落盘，用于命令行冒烟与测试。
class MemoryKeyValueStore implements KeyValueStore {
  final Map<String, String> _data = <String, String>{};

  Map<String, String> get snapshot => Map.unmodifiable(_data);

  @override
  String? getString(String key) => _data[key];

  @override
  Future<void> setString(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _data.remove(key);
  }
}
