import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../api/key_value_store.dart';
import 'dictionary_pack_config.dart';

class DictionaryInstallState {
  const DictionaryInstallState({
    required this.version,
    required this.installedAt,
    required this.size,
    required this.sha256,
  });

  final String version;
  final DateTime installedAt;
  final int size;
  final String sha256;

  Map<String, dynamic> toJson() => {
        'version': version,
        'installedAt': installedAt.toIso8601String(),
        'size': size,
        'sha256': sha256,
      };

  factory DictionaryInstallState.fromJson(Map<String, dynamic> json) =>
      DictionaryInstallState(
        version: json['version']?.toString() ?? '',
        installedAt:
            DateTime.tryParse(json['installedAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        size: (json['size'] as num?)?.toInt() ?? 0,
        sha256: json['sha256']?.toString() ?? '',
      );
}

/// 所选词库类型 + 每种词库各自的安装状态。
///
/// 旧版本 `dictionary_state` 是单个安装状态 JSON，按精简词库迁移。
class DictionaryStateStore extends ChangeNotifier {
  DictionaryStateStore(this._kv);

  final KeyValueStore _kv;
  static const String key = 'dictionary_state';

  DictionaryMode _mode = DictionaryMode.simple;
  DictionaryMode get mode => _mode;

  final Map<DictionaryMode, DictionaryInstallState> _states = {};

  DictionaryInstallState? get state => _states[_mode];
  bool get isInstalled => state != null;

  DictionaryInstallState? stateFor(DictionaryMode mode) => _states[mode];
  bool isInstalledFor(DictionaryMode mode) => _states[mode] != null;

  void load() {
    _mode = DictionaryMode.simple;
    _states.clear();
    final raw = _kv.getString(key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final savedMode = decoded['mode']?.toString();
          _mode = DictionaryMode.values.firstWhere(
            (mode) => mode.name == savedMode,
            orElse: () => DictionaryMode.simple,
          );
          final states = decoded['states'];
          if (states is Map) {
            states.forEach((key, value) {
              final mode = DictionaryMode.values.firstWhere(
                (mode) => mode.name == key?.toString(),
                orElse: () => DictionaryMode.simple,
              );
              if (value is Map) {
                _states[mode] =
                    DictionaryInstallState.fromJson(Map<String, dynamic>.from(value));
              }
            });
          } else {
            _states[DictionaryMode.simple] =
                DictionaryInstallState.fromJson(Map<String, dynamic>.from(decoded));
          }
        }
      } catch (e) {
        debugPrint('[dictionary] 读取状态失败：$e');
        _mode = DictionaryMode.simple;
        _states.clear();
      }
    }
    notifyListeners();
  }

  Future<void> setMode(DictionaryMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    await _persist();
    notifyListeners();
  }

  Future<void> save(DictionaryInstallState state) async {
    _states[_mode] = state;
    await _persist();
    notifyListeners();
  }

  Future<void> clear() async {
    _states.remove(_mode);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    await _kv.setString(
      key,
      jsonEncode(<String, dynamic>{
        'mode': _mode.name,
        'states': _states.map(
          (mode, state) => MapEntry<String, dynamic>(mode.name, state.toJson()),
        ),
      }),
    );
  }
}
