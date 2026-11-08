import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../api/key_value_store.dart';
import 'tts_engine.dart';

/// TTS 设置持久化（`tts_settings`，M9.3 建立，M9.4 设置页消费）。
class TtsSettingsStore extends ChangeNotifier {
  TtsSettingsStore(this._kv);

  static const storageKey = 'tts_settings';

  /// 已下线的 MiMo 朗读 Key，读取设置时顺手清除本机残留凭据。
  static const removedMimoKeyStorageKey = 'mimo_api_key';

  final KeyValueStore _kv;
  bool _loaded = false;

  TtsEngineKind _engine = TtsEngineKind.edge;
  String _systemVoice = '';
  String _edgeVoice = 'zh-CN-XiaoxiaoNeural';
  double _rate = 1.0;
  double _pitch = 1.0;

  bool get loaded => _loaded;
  TtsEngineKind get engine => _engine;
  String get systemVoice => _systemVoice;
  String get edgeVoice => _edgeVoice;
  double get rate => _rate;
  double get pitch => _pitch;

  /// 当前引擎使用的音色。
  String get activeVoice => switch (_engine) {
        TtsEngineKind.system => _systemVoice,
        TtsEngineKind.edge => _edgeVoice,
      };

  Future<void> load() async {
    final raw = _kv.getString(storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _applyJson(Map<String, dynamic>.from(decoded));
        }
      } catch (e) {
        debugPrint('[tts] 读取 tts_settings 失败：$e');
      }
    }
    if (_kv.getString(removedMimoKeyStorageKey) != null) {
      await _kv.remove(removedMimoKeyStorageKey);
    }
    _loaded = true;
    notifyListeners();
  }

  void _applyJson(Map<String, dynamic> json) {
    // 旧版本可能存着 mimo / http 引擎，fromStorage 会自动回落到 Edge。
    _engine = TtsEngineKindX.fromStorage(json['engine']?.toString());
    _systemVoice = json['systemVoice']?.toString() ?? '';
    _edgeVoice = json['edgeVoice']?.toString() ?? 'zh-CN-XiaoxiaoNeural';
    _rate = ((json['rate'] as num?)?.toDouble() ?? 1.0).clamp(0.5, 3.0);
    _pitch = ((json['pitch'] as num?)?.toDouble() ?? 1.0).clamp(0.5, 2.0);
  }

  Map<String, dynamic> toJson() => {
        'engine': _engine.storageValue,
        'systemVoice': _systemVoice,
        'edgeVoice': _edgeVoice,
        'rate': _rate,
        'pitch': _pitch,
      };

  Future<void> _persist() async {
    await _kv.setString(storageKey, jsonEncode(toJson()));
  }

  Future<void> setEngine(TtsEngineKind kind) async {
    if (_engine == kind) return;
    _engine = kind;
    notifyListeners();
    await _persist();
  }

  Future<void> setSystemVoice(String voice) async {
    _systemVoice = voice;
    notifyListeners();
    await _persist();
  }

  Future<void> setEdgeVoice(String voice) async {
    _edgeVoice = voice;
    notifyListeners();
    await _persist();
  }

  Future<void> setRate(double rate) async {
    _rate = rate.clamp(0.5, 3.0);
    notifyListeners();
    await _persist();
  }

  Future<void> setPitch(double pitch) async {
    _pitch = pitch.clamp(0.5, 2.0);
    notifyListeners();
    await _persist();
  }

  /// 当前参数快照。
  TtsParams get params =>
      TtsParams(voice: activeVoice, rate: _rate, pitch: _pitch);
}
