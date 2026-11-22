import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../api/key_value_store.dart';

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

class DictionaryStateStore extends ChangeNotifier {
  DictionaryStateStore(this._kv);

  final KeyValueStore _kv;
  static const String key = 'dictionary_state';
  static const String customUrlKey = 'dictionary_custom_url';

  DictionaryInstallState? _state;
  DictionaryInstallState? get state => _state;
  bool get isInstalled => _state != null;

  String? _customUrl;
  String? get customUrl => _customUrl;

  void load() {
    _customUrl = _kv.getString(customUrlKey);
    final raw = _kv.getString(key);
    if (raw == null || raw.isEmpty) {
      _state = null;
    } else {
      try {
        _state = DictionaryInstallState.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map),
        );
      } catch (e) {
        debugPrint('[dictionary] 读取状态失败：$e');
        _state = null;
      }
    }
    notifyListeners();
  }

  Future<void> save(DictionaryInstallState state) async {
    _state = state;
    await _kv.setString(key, jsonEncode(state.toJson()));
    notifyListeners();
  }

  Future<void> clear() async {
    _state = null;
    await _kv.remove(key);
    notifyListeners();
  }

  Future<void> setCustomUrl(String? url) async {
    final trimmed = url?.trim() ?? '';
    _customUrl = trimmed.isEmpty ? null : trimmed;
    if (_customUrl == null) {
      await _kv.remove(customUrlKey);
    } else {
      await _kv.setString(customUrlKey, _customUrl!);
    }
    notifyListeners();
  }
}
