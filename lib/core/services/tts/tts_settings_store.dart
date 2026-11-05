import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../api/key_value_store.dart';
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

  final KeyValueStore _kv;
  bool _loaded = false;

  TtsEngineKind _engine = TtsEngineKind.edge;
  String _systemVoice = '';
  String _edgeVoice = 'zh-CN-XiaoxiaoNeural';
  double _rate = 1.0;
  double _pitch = 1.0;
  String? _httpTemplateId;
  List<TtsHttpTemplate> _templates = const [];
  bool _defaultListen = false;

  bool get loaded => _loaded;
  TtsEngineKind get engine => _engine;
  String get systemVoice => _systemVoice;
  String get edgeVoice => _edgeVoice;
  double get rate => _rate;
  double get pitch => _pitch;
  String? get httpTemplateId => _httpTemplateId;
  List<TtsHttpTemplate> get templates => List.unmodifiable(_templates);

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
    _loaded = true;
    notifyListeners();
  }

  void _applyJson(Map<String, dynamic> json) {
    _engine = TtsEngineKindX.fromStorage(json['engine']?.toString());
    _systemVoice = json['systemVoice']?.toString() ?? '';
    _edgeVoice =
        json['edgeVoice']?.toString() ?? 'zh-CN-XiaoxiaoNeural';
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
