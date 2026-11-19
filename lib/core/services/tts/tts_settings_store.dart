import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../api/key_value_store.dart';
import 'tts_engine.dart';

/// TTS 设置持久化（`tts_settings`，M9.3 建立，M9.4 设置页消费）。
class TtsSettingsStore extends ChangeNotifier {
  TtsSettingsStore(this._kv);

  static const storageKey = 'tts_settings';

  /// 语速/音调的 UI 调节步长：1.0 → 0.9 → 0.8 这样逐级切换。
  static const double paramStep = 0.1;

  /// 把滑杆浮点值归到 0.1 网格，避免 0.9000000000000001 这类值落盘。
  static double quantizeParam(double value) =>
      (value / paramStep).round() * paramStep;

  /// 豆包登录 Cookie 单独存放，与 [storageKey] 的普通设置分离。
  /// 凭据类数据由备份系统归入 payload.secure（见 BackupWhitelist.secureItems）。
  static const doubaoCookieStorageKey = 'doubao_tts_cookie';

  /// 早期版本曾把 Cookie 内嵌在 tts_settings 里的字段名。迁移与备份导出
  /// 都据此擦除，避免明文 Cookie 混进普通设置区。
  static const legacyDoubaoCookieField = 'doubaoCookie';

  /// 已下线的 MiMo 朗读 Key，读取设置时顺手清除本机残留凭据。
  static const removedMimoKeyStorageKey = 'mimo_api_key';

  final KeyValueStore _kv;
  bool _loaded = false;

  TtsEngineKind _engine = TtsEngineKind.edge;
  String _systemVoice = '';
  String _edgeVoice = 'zh-CN-XiaoxiaoNeural';
  String _doubaoVoice = doubaoDefaultVoiceId;
  String _doubaoCookie = '';
  double _rate = 1.0;
  double _pitch = 1.0;

  bool get loaded => _loaded;
  TtsEngineKind get engine => _engine;
  String get systemVoice => _systemVoice;
  String get edgeVoice => _edgeVoice;
  String get doubaoVoice => _doubaoVoice;
  String get doubaoCookie => _doubaoCookie;
  double get rate => _rate;
  double get pitch => _pitch;

  /// 当前引擎使用的音色。
  String get activeVoice => switch (_engine) {
        TtsEngineKind.system => _systemVoice,
        TtsEngineKind.edge => _edgeVoice,
        TtsEngineKind.doubao => _doubaoVoice,
      };

  Future<void> load() async {
    final raw = _kv.getString(storageKey);
    Map<String, dynamic>? stored;
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) stored = Map<String, dynamic>.from(decoded);
      } catch (e) {
        debugPrint('[tts] 读取 tts_settings 失败：$e');
      }
    }

    // Cookie 从独立凭据 key 读取。兼容早期内嵌在 tts_settings 里的旧数据：
    // 迁移到独立 key 后把明文字段从普通设置里擦除（避免明文随设置外泄）。
    var legacyFieldFound = false;
    String legacyCookie = '';
    if (stored != null && stored.containsKey(legacyDoubaoCookieField)) {
      legacyFieldFound = true;
      legacyCookie = stored.remove(legacyDoubaoCookieField)?.toString() ?? '';
    }
    _doubaoCookie = (_kv.getString(doubaoCookieStorageKey) ?? '').trim();
    if (_doubaoCookie.isEmpty && legacyCookie.isNotEmpty) {
      _doubaoCookie = legacyCookie;
      await _kv.setString(doubaoCookieStorageKey, _doubaoCookie);
    }
    if (stored != null) {
      _applyJson(stored);
      if (legacyFieldFound) await _kv.setString(storageKey, jsonEncode(stored));
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
    _doubaoVoice = json['doubaoVoice']?.toString() ?? doubaoDefaultVoiceId;
    _rate = ((json['rate'] as num?)?.toDouble() ?? 1.0).clamp(0.5, 3.0);
    _pitch = ((json['pitch'] as num?)?.toDouble() ?? 1.0).clamp(0.5, 2.0);
  }

  Map<String, dynamic> toJson() => {
        'engine': _engine.storageValue,
        'systemVoice': _systemVoice,
        'edgeVoice': _edgeVoice,
        'doubaoVoice': _doubaoVoice,
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

  Future<void> setDoubaoVoice(String voice) async {
    _doubaoVoice = voice;
    notifyListeners();
    await _persist();
  }

  /// 保存豆包登录 Cookie 到独立凭据 key。空串表示清空凭据。
  Future<void> setDoubaoCookie(String cookie) async {
    _doubaoCookie = cookie.trim();
    notifyListeners();
    if (_doubaoCookie.isEmpty) {
      await _kv.remove(doubaoCookieStorageKey);
    } else {
      await _kv.setString(doubaoCookieStorageKey, _doubaoCookie);
    }
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

  /// 一次套用听书预设，避免连续写入时产生中间状态。
  Future<void> applyVoicePreset(TtsVoicePreset preset) async {
    _edgeVoice = preset.voiceId;
    _rate = preset.rate.clamp(0.5, 3.0);
    _pitch = preset.pitch.clamp(0.5, 2.0);
    notifyListeners();
    await _persist();
  }

  /// 当前参数快照。
  TtsParams get params =>
      TtsParams(voice: activeVoice, rate: _rate, pitch: _pitch);
}
