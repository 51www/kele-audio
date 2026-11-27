import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../api/key_value_store.dart';
import 'doubao_cookie_pool.dart';
import 'doubao_tts_client.dart';
import 'mimo_tts_client.dart';
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

  /// MiMo API Key 单独存放：不进 tts_settings JSON，任何日志都不打印原文。
  /// 凭据类数据由备份系统归入 payload.secure（见 BackupWhitelist.secureItems）。
  static const mimoKeyStorageKey = 'mimo_api_key';

  /// 构建时注入的默认 Key（`--dart-define=MIMO_API_KEY=...`），本地未覆盖时生效。
  static const String _builtInMimoKey = String.fromEnvironment('MIMO_API_KEY');

  final KeyValueStore _kv;
  bool _loaded = false;

  TtsEngineKind _engine = TtsEngineKind.edge;
  String _systemVoice = '';
  String _edgeVoice = 'zh-CN-XiaoxiaoNeural';
  String _doubaoVoice = doubaoDefaultVoiceId;
  String _doubaoCookie = '';
  String _mimoVoice = 'mimo_default';
  List<String> _mimoVoices = const [];
  bool _mimoKeyStored = false;
  String _mimoKey = '';
  double _rate = 1.0;
  double _pitch = 1.0;

  bool get loaded => _loaded;
  TtsEngineKind get engine => _engine;
  String get systemVoice => _systemVoice;
  String get edgeVoice => _edgeVoice;
  String get doubaoVoice => _doubaoVoice;
  String get doubaoCookie => _doubaoCookie;
  String get mimoVoice => _mimoVoice;
  double get rate => _rate;
  double get pitch => _pitch;

  /// 当前生效的 MiMo Key（本地优先，其次构建注入）。
  String get mimoApiKey => _mimoKeyStored ? _mimoKey : _builtInMimoKey;

  bool get hasMimoApiKey => mimoApiKey.trim().isNotEmpty;

  /// 设置页展示用（首尾各 4 位，绝不回显完整 Key）。
  String get maskedMimoKey => maskApiKey(mimoApiKey);

  /// 是否已有 400 探测音色缓存（没有则先展示内置兜底清单）。
  bool get hasCachedMimoVoices => _mimoVoices.isNotEmpty;

  /// 音色列表：优先用 400 探测缓存，失败/未探测时用内置兜底清单。
  List<TtsVoice> get mimoVoiceOptions => _mimoVoices.isEmpty
      ? mimoFallbackVoices
      : [
          for (final id in _mimoVoices)
            TtsVoice(id: id, name: mimoVoiceLabel(id)),
        ];

  /// 当前引擎使用的音色。
  String get activeVoice => switch (_engine) {
        TtsEngineKind.system => _systemVoice,
        TtsEngineKind.edge => _edgeVoice,
        TtsEngineKind.doubao => _doubaoVoice,
        TtsEngineKind.mimo => _mimoVoice,
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

    // 设置（含 Cookie）可能来自启动加载，也可能来自备份还原。无论哪种，
    // 都要重置豆包轮询池与节流退避：否则导入新 Cookie 后仍沿用旧账号的
    // 失败冷却/退避，下一次朗读被无故限流，误判成「导入后风控」。
    DoubaoTtsCookiePool.instance.reset();
    DoubaoTtsThrottle.instance.reset();

    // MiMo API Key 从独立凭据 key 读取（本地优先，其次构建注入）。
    final storedMimoKey = _kv.getString(mimoKeyStorageKey);
    _mimoKeyStored = storedMimoKey != null;
    _mimoKey = storedMimoKey ?? '';
    _loaded = true;
    notifyListeners();
  }

  void _applyJson(Map<String, dynamic> json) {
    // 旧版本可能存着 http 引擎，fromStorage 会自动回落到 Edge。
    _engine = TtsEngineKindX.fromStorage(json['engine']?.toString());
    _systemVoice = json['systemVoice']?.toString() ?? '';
    _edgeVoice = json['edgeVoice']?.toString() ?? 'zh-CN-XiaoxiaoNeural';
    // 豆包会下线旧音色 ID（服务端对未知 speaker 静默回退默认女声），
    // 存量设置里若是不在当前清单中的旧 ID，回退到当前默认音色。
    final storedDoubaoVoice = json['doubaoVoice']?.toString();
    _doubaoVoice = (storedDoubaoVoice != null &&
            storedDoubaoVoice.isNotEmpty &&
            doubaoZhVoices.any((v) => v.id == storedDoubaoVoice))
        ? storedDoubaoVoice
        : doubaoDefaultVoiceId;
    _mimoVoice = json['mimoVoice']?.toString() ?? 'mimo_default';
    final cachedVoices = json['mimoVoices'];
    _mimoVoices = cachedVoices is List
        ? [for (final v in cachedVoices) v.toString()]
        : const [];
    _rate = ((json['rate'] as num?)?.toDouble() ?? 1.0).clamp(0.5, 3.0);
    _pitch = ((json['pitch'] as num?)?.toDouble() ?? 1.0).clamp(0.5, 2.0);
  }

  Map<String, dynamic> toJson() => {
        'engine': _engine.storageValue,
        'systemVoice': _systemVoice,
        'edgeVoice': _edgeVoice,
        'doubaoVoice': _doubaoVoice,
        'mimoVoice': _mimoVoice,
        'mimoVoices': _mimoVoices,
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
    // 只接受当前清单内的有效音色；豆包会下线旧 ID，存进去只会静默回退。
    _doubaoVoice =
        doubaoZhVoices.any((v) => v.id == voice) ? voice : doubaoDefaultVoiceId;
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
    // Cookie 列表变更：重置轮询游标与冷却，立即启用新配置。
    DoubaoTtsCookiePool.instance.reset();
  }

  Future<void> setMimoVoice(String voice) async {
    if (_mimoVoice == voice) return;
    _mimoVoice = voice;
    notifyListeners();
    await _persist();
  }

  /// 缓存 400 探测到的可用音色；清单变化时把当前音色对齐到有效项。
  Future<void> setMimoVoices(List<String> voices) async {
    final next = [for (final v in voices) v.trim()]
        .where((v) => v.isNotEmpty)
        .toList();
    if (listEquals(_mimoVoices, next)) return;
    _mimoVoices = next;
    if (next.isNotEmpty && !next.contains(_mimoVoice)) {
      _mimoVoice = next.first;
    }
    notifyListeners();
    await _persist();
  }

  /// 保存 MiMo API Key 到独立凭据 key。空串表示清空凭据。
  Future<void> setMimoApiKey(String key) async {
    _mimoKeyStored = true;
    _mimoKey = key.trim();
    notifyListeners();
    if (_mimoKey.isEmpty) {
      await _kv.remove(mimoKeyStorageKey);
    } else {
      await _kv.setString(mimoKeyStorageKey, _mimoKey);
    }
  }

  Future<void> clearMimoApiKey() => setMimoApiKey('');

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
