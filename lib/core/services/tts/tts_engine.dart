import 'dart:typed_data';

/// 听书引擎类型（docs/reader-design.md §5.1）。
enum TtsEngineKind { system, edge, http }

extension TtsEngineKindX on TtsEngineKind {
  String get storageValue => name;

  String get label => switch (this) {
    TtsEngineKind.system => '系统',
    TtsEngineKind.edge => 'Edge',
    TtsEngineKind.http => '自定义 HTTP',
  };

  static TtsEngineKind fromStorage(String? value) {
    for (final kind in TtsEngineKind.values) {
      if (kind.storageValue == value) return kind;
    }
    return TtsEngineKind.edge;
  }
}

/// 可选音色。
class TtsVoice {
  const TtsVoice({
    required this.id,
    required this.name,
    this.locale = 'zh-CN',
  });

  final String id;
  final String name;
  final String locale;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'locale': locale,
  };

  factory TtsVoice.fromJson(Map<String, dynamic> json) => TtsVoice(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    locale: json['locale']?.toString() ?? 'zh-CN',
  );
}

/// 朗读参数：语速 0.5~3.0、音调 0.5~2.0。
class TtsParams {
  const TtsParams({
    this.voice = '',
    this.rate = 1.0,
    this.pitch = 1.0,
  });

  final String voice;
  final double rate;
  final double pitch;

  TtsParams copyWith({String? voice, double? rate, double? pitch}) =>
      TtsParams(
        voice: voice ?? this.voice,
        rate: rate ?? this.rate,
        pitch: pitch ?? this.pitch,
      );
}

/// 引擎异常：code 用于 UI 归类（network / auth / config / unsupported）。
class TtsException implements Exception {
  const TtsException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'TtsException($code): $message';
}

/// TTS 引擎抽象（docs/reader-design.md §5.1）。
///
/// 一次只朗读一段文本：`speak` 在**该段播放完成**后返回；
/// [prefetch] 可提前合成下一段（Edge/HTTP 减少段间停顿）。
abstract class TtsEngine {
  String get id;

  Future<void> start(TtsParams params);

  /// 预合成下一段（可选能力，默认不做事）。
  void prefetch(String text) {}

  /// 合成并播放一段，完成后返回。
  Future<void> speak(String text);

  /// 丢弃合成队列并停止播放。
  Future<void> stop();

  /// 设置页连通性自检。
  Future<void> testConnection();

  Future<void> dispose();
}

/// Edge TTS 常用中文音色（离线内置清单，设置页可直接选择）。
const List<TtsVoice> edgeZhVoices = [
  TtsVoice(id: 'zh-CN-XiaoxiaoNeural', name: '晓晓 · 女声'),
  TtsVoice(id: 'zh-CN-XiaoyiNeural', name: '晓伊 · 女声'),
  TtsVoice(id: 'zh-CN-YunxiNeural', name: '云希 · 男声'),
  TtsVoice(id: 'zh-CN-YunjianNeural', name: '云健 · 男声'),
  TtsVoice(id: 'zh-CN-YunyangNeural', name: '云扬 · 男声'),
  TtsVoice(id: 'zh-CN-liaoning-XiaobeiNeural', name: '晓北 · 东北女声'),
  TtsVoice(id: 'zh-TW-HsiaoChenNeural', name: '曉臻 · 台湾女声'),
];

/// 测试用：返回固定音频的假引擎（不参与生产装配）。
class FakeTtsEngine implements TtsEngine {
  FakeTtsEngine({this.fail = false});

  final bool fail;
  final List<String> spoken = [];

  @override
  String get id => 'fake';

  @override
  Future<void> start(TtsParams params) async {}

  @override
  void prefetch(String text) {}

  @override
  Future<void> speak(String text) async {
    if (fail) throw const TtsException('fake', '测试失败');
    spoken.add(text);
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> testConnection() async {
    if (fail) throw const TtsException('fake', '测试失败');
  }

  @override
  Future<void> dispose() async {}
}

/// 语音数据占位（引擎内部使用）。
typedef TtsAudioBytes = Uint8List;
