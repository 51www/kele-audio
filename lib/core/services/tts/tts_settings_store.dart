import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../api/key_value_store.dart';
import 'mimo_tts_client.dart';
import 'tts_engine.dart';

/// 自定义 HTTP 朗读模板（URL 支持 `{text}` / `{voice}` / `{rate}` 占位符）。
class TtsHttpTemplate {
  const TtsHttpTemplate({
    required this.id,
    required this.name,
    required this.url,
    this.headers = const {},
  });

  final String id;
  final String name;
  final String url;
  final Map<String, String> headers;

  TtsHttpTemplate copyWith({
    String? name,
    String? url,
    Map<String, String>? headers,
  }) => TtsHttpTemplate(
    id: id,
    name: name ?? this.name,
    url: url ?? this.url,
    headers: headers ?? this.headers,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'headers': headers,
  };

  factory TtsHttpTemplate.fromJson(Map<String, dynamic> json) => TtsHttpTemplate(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '未命名模板',
    url: json['url']?.toString() ?? '',
    headers: {
      for (final e in (json['headers'] as Map? ?? const {}).entries)
        e.key.toString(): e.value.toString(),
    },
  );
}

/// TTS 设置持久化（`tts_settings`，M9.3 建立，M9.4 设置页消费）。
class TtsSettingsStore extends ChangeNotifier {
  TtsSettingsStore(this._kv);

  static const storageKey = 'tts_settings';

  /// MiMo API Key 单独存放：不进 tts_settings JSON，任何日志都不打印原文。
  static const mimoKeyStorageKey = 'mimo_api_key';

  /// 构建时注入的默认 Key（`--dart-define=MIMO_API_KEY=...`），本地未覆盖时生效。
  static const String _builtInMimoKey = String.fromEnvironment('MIMO_API_KEY');

  final KeyValueStore _kv;
  bool _loaded = false;

  TtsEngineKind _engine = TtsEngineKind.edge;
  String _systemVoice = '';
  String _edgeVoice = 'zh-CN-XiaoxiaoNeural';
  String _mimoVoice = 'mimo_default';
  List<String> _mimoVoices = const [];
  double _rate = 1.0;
  double _pitch = 1.0;
  String? _httpTemplateId;
  List<TtsHttpTemplate> _templates = const [];
  bool _defaultListen = false;

  /// 本地是否保存过 Key（空串也算「已清除」，避免清除后又回落到构建注入值）。
  bool _mimoKeyStored = false;
  String _mimoKey = '';

  bool get loaded => _loaded;
  TtsEngineKind get engine => _engine;
  String get systemVoice => _systemVoice;
  String get edgeVoice => _edgeVoice;
  String get mimoVoice => _mimoVoice;
  double get rate => _rate;
  double get pitch => _pitch;
  String? get httpTemplateId => _httpTemplateId;
  List<TtsHttpTemplate> get templates => List.unmodifiable(_templates);

  /// 当前生效的 MiMo Key（本地优先，其次构建注入）。
  String get mimoApiKey => _mimoKeyStored ? _mimoKey : _builtInMimoKey;

  bool get hasMimoApiKey => mimoApiKey.trim().isNotEmpty;

  /// 设置页展示用（首尾各 4 位，绝不回显完整 Key）。
  String get maskedMimoKey => maskApiKey(mimoApiKey);

  /// 是否已有 400 探测音色缓存（没有则先展示内置 9 个兜底）。
  bool get hasCachedMimoVoices => _mimoVoices.isNotEmpty;

  /// 音色列表：优先用 400 探测缓存，失败/未探测时用内置 9 个兜底。
  List<TtsVoice> get mimoVoiceOptions => _mimoVoices.isEmpty
      ? mimoFallbackVoices
      : [
          for (final id in _mimoVoices)
            TtsVoice(id: id, name: mimoVoiceLabel(id)),
        ];

  /// 进入书籍后是否默认继续听书（否则默认静读）。
  bool get defaultListen => _defaultListen;

  TtsHttpTemplate? get httpTemplate {
    final id = _httpTemplateId;
    if (id == null) return _templates.isEmpty ? null : _templates.first;
    for (final t in _templates) {
      if (t.id == id) return t;
    }
    return _templates.isEmpty ? null : _templates.first;
  }

  /// 当前引擎使用的音色（HTTP 档可为空）。
  String get activeVoice => switch (_engine) {
    TtsEngineKind.system => _systemVoice,
    TtsEngineKind.edge => _edgeVoice,
    TtsEngineKind.mimo => _mimoVoice,
    TtsEngineKind.http => '',
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
    // Key 单独存储：null 表示从未在本地设置过，沿用构建注入的默认值。
    final storedKey = _kv.getString(mimoKeyStorageKey);
    _mimoKeyStored = storedKey != null;
    _mimoKey = storedKey ?? '';
    _loaded = true;
    notifyListeners();
  }

  void _applyJson(Map<String, dynamic> json) {
    _engine = TtsEngineKindX.fromStorage(json['engine']?.toString());
    _systemVoice = json['systemVoice']?.toString() ?? '';
    _edgeVoice =
        json['edgeVoice']?.toString() ?? 'zh-CN-XiaoxiaoNeural';
    _mimoVoice = json['mimoVoice']?.toString() ?? 'mimo_default';
    final cachedVoices = json['mimoVoices'];
    _mimoVoices = cachedVoices is List
        ? [
            for (final item in cachedVoices)
              if (item is String && item.isNotEmpty) item,
          ]
        : const [];
    _rate = ((json['rate'] as num?)?.toDouble() ?? 1.0).clamp(0.5, 3.0);
    _pitch = ((json['pitch'] as num?)?.toDouble() ?? 1.0).clamp(0.5, 2.0);
    _httpTemplateId = json['httpTemplateId']?.toString();
    _defaultListen = json['defaultListen'] == true;
    final raw = json['templates'];
    _templates = raw is List
        ? [
            for (final item in raw)
              if (item is Map)
                TtsHttpTemplate.fromJson(Map<String, dynamic>.from(item)),
          ]
        : const [];
  }

  Map<String, dynamic> toJson() => {
    'engine': _engine.storageValue,
    'systemVoice': _systemVoice,
    'edgeVoice': _edgeVoice,
    'mimoVoice': _mimoVoice,
    'mimoVoices': _mimoVoices,
    'rate': _rate,
    'pitch': _pitch,
    'httpTemplateId': _httpTemplateId,
    'defaultListen': _defaultListen,
    'templates': [for (final t in _templates) t.toJson()],
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

  Future<void> setMimoVoice(String voice) async {
    if (_mimoVoice == voice) return;
    _mimoVoice = voice;
    notifyListeners();
    await _persist();
  }

  /// 缓存 400 探测到的音色清单（探测失败时保持为空 → 使用兜底 9 个）。
  Future<void> setMimoVoices(List<String> voices) async {
    final next = List<String>.unmodifiable(
      voices.where((v) => v.trim().isNotEmpty).toSet(),
    );
    if (listEquals(_mimoVoices, next)) return;
    _mimoVoices = next;
    if (next.isNotEmpty && !next.contains(_mimoVoice)) {
      _mimoVoice = next.first;
    }
    notifyListeners();
    await _persist();
  }

  /// 保存本地 Key；空串表示明确清除（不再回落到构建注入值）。
  Future<void> setMimoApiKey(String key) async {
    _mimoKeyStored = true;
    _mimoKey = key.trim();
    notifyListeners();
    await _kv.setString(mimoKeyStorageKey, _mimoKey);
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

  Future<void> setDefaultListen(bool value) async {
    _defaultListen = value;
    notifyListeners();
    await _persist();
  }

  Future<void> setHttpTemplate(String? id) async {
    _httpTemplateId = id;
    notifyListeners();
    await _persist();
  }

  Future<void> upsertTemplate(TtsHttpTemplate template) async {
    final next = _templates.toList();
    final index = next.indexWhere((t) => t.id == template.id);
    if (index >= 0) {
      next[index] = template;
    } else {
      next.add(template);
    }
    _templates = next;
    _httpTemplateId ??= template.id;
    notifyListeners();
    await _persist();
  }

  Future<void> removeTemplate(String id) async {
    _templates = _templates.where((t) => t.id != id).toList();
    if (_httpTemplateId == id) {
      _httpTemplateId = _templates.isEmpty ? null : _templates.first.id;
    }
    notifyListeners();
    await _persist();
  }

  /// 当前参数快照。
  TtsParams get params => TtsParams(
    voice: activeVoice,
    rate: _rate,
    pitch: _pitch,
  );
}
