import 'dart:typed_data';

/// 听书引擎类型（docs/reader-design.md §5.1）。
enum TtsEngineKind { system, edge, doubao }

extension TtsEngineKindX on TtsEngineKind {
  String get storageValue => name;

  String get label => switch (this) {
    TtsEngineKind.system => '系统',
    TtsEngineKind.edge => 'Edge',
    TtsEngineKind.doubao => '豆包',
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
/// [prefetch] 可提前合成下一段（Edge 减少段间停顿）。
abstract class TtsEngine {
  String get id;

  Future<void> start(TtsParams params);

  /// 预合成下一段（可选能力，默认不做事）。
  void prefetch(String text) {}

  /// 合成并播放一段，完成后返回。
  Future<void> speak(String text);

  /// 丢弃合成队列并停止播放。
  Future<void> stop();

  /// 换章时清理该章缓存（无缓存的引擎留空实现）。
  void resetCache();

  /// 设置页连通性自检。
  Future<void> testConnection();

  Future<void> dispose();
}

/// 标记接口：有风控的在线引擎（豆包）实现它，朗读会话据此采用「多句合并 +
/// 收窄预取」以降低请求次数。系统/Edge 不实现，保持逐句、首包快、高亮精确。
abstract class BatchingTtsEngine {
  /// 单个请求合并的最大句数。
  int get maxSentencesPerSegment;

  /// 预取深度（风控引擎取 1，避免瞬间连发多个请求）。
  int get prefetchDepth;
}

/// Edge TTS 常用中文音色（离线内置清单，设置页可直接选择）。
const List<TtsVoice> edgeZhVoices = [
  TtsVoice(id: 'zh-CN-XiaoxiaoNeural', name: '晓晓 · 女声'),
  TtsVoice(id: 'zh-CN-XiaoyiNeural', name: '晓伊 · 女声'),
  TtsVoice(id: 'zh-CN-YunxiNeural', name: '云希 · 男声'),
  TtsVoice(id: 'zh-CN-YunjianNeural', name: '云健 · 男声'),
  TtsVoice(id: 'zh-CN-YunyangNeural', name: '云扬 · 男声'),
  TtsVoice(id: 'zh-CN-liaoning-XiaobeiNeural', name: '晓北 · 东北女声'),
  TtsVoice(id: 'zh-CN-shaanxi-XiaoniNeural', name: '晓妮 · 陕西女声'),
  TtsVoice(id: 'zh-TW-HsiaoChenNeural', name: '曉臻 · 台湾女声'),
  TtsVoice(id: 'zh-TW-HsiaoYuNeural', name: '曉語 · 台湾女声'),
  TtsVoice(id: 'zh-TW-YunJheNeural', name: '雲哲 · 台湾男声'),
  TtsVoice(id: 'zh-HK-HiuMaanNeural', name: '曉曼 · 粤语女声'),
];

/// 豆包默认音色 ID（温柔桃子）。
///
/// 注意：豆包已下线 2025 年初的旧音色 ID（如 zh_female_taozi_conversation_v4_
/// wvae_bigtts），对未知 speaker 服务端会静默回退默认女声（基频实测 ≈279Hz）。
/// 当前有效音色经合成基频验证（男声 F0 103-146Hz，2026-11）。
const String doubaoDefaultVoiceId =
    'zh_female_wenroutaozi_uranus_bigtts';

/// 豆包 TTS 内置中文音色（离线内置清单，需要登录 Cookie）。
/// 男声 ID 均经真实合成 + 基频分析验证有效（F0<165Hz）；失效 ID 已剔除。
const List<TtsVoice> doubaoZhVoices = [
  TtsVoice(id: 'zh_female_wenroutaozi_uranus_bigtts', name: '温柔桃子 · 女声'),
  TtsVoice(
    id: 'zh_female_xiaohe_conversation_wvae_bigtts',
    name: '阳光甜妹 · 女声',
  ),
  TtsVoice(id: 'zh_female_sophie_conversation_wvae_bigtts', name: '魅力苏菲 · 女声'),
  TtsVoice(id: 'zh_female_beijingdaniu_mars_bigtts', name: '北京大妞 · 女声'),
  TtsVoice(id: 'zh_female_F466_mars_bigtts', name: '清甜瑶瑶 · 女声'),
  TtsVoice(id: 'zh_female_maomao_conversation_wvae_bigtts', name: '文静毛毛 · 女声'),
  TtsVoice(
    id: 'zh_male_nuanxinshizhe_mars_bigtts',
    name: '磁性俊宇 · 男声',
  ),
  TtsVoice(
    id: 'zh_male_M100_conversation_wvae_bigtts',
    name: '悠悠君子 · 男声',
  ),
  TtsVoice(id: 'zh_male_ahu_conversation_wvae_bigtts', name: '温暖阿虎 · 男声'),
  TtsVoice(
    id: 'zh_male_qingyiyuxuan_mars_bigtts',
    name: '阳光阿辰 · 男声',
  ),
  TtsVoice(
    id: 'zh_male_aojiaobazong_wvae_bigtts',
    name: '傲娇霸总 · 男声',
  ),
  TtsVoice(id: 'zh_male_cheng_mars_bigtts', name: '温柔子言 · 男声'),
  TtsVoice(
    id: 'zh_male_shenyeboke_wvae_bigtts',
    name: '深夜播客 · 男声',
  ),
  TtsVoice(
    id: 'zh_male_dongfanghaoran_moon_bigtts',
    name: '东方浩然 · 男声',
  ),
];

/// 听书场景预设：一次套用音色、语速与音调。
class TtsVoicePreset {
  const TtsVoicePreset({
    required this.name,
    required this.voiceId,
    required this.rate,
    required this.pitch,
    required this.description,
  });

  final String name;
  final String voiceId;
  final double rate;
  final double pitch;
  final String description;

  bool matches({
    required String voice,
    required double rate,
    required double pitch,
  }) =>
      voiceId == voice && this.rate == rate && this.pitch == pitch;
}

/// Edge 听书预设：仅选择参数，不改变默认引擎或默认音色。
const List<TtsVoicePreset> edgeVoicePresets = [
  TtsVoicePreset(
    name: '标准听书',
    voiceId: 'zh-CN-XiaoxiaoNeural',
    rate: 1.0,
    pitch: 1.0,
    description: '晓晓 · 清晰自然',
  ),
  TtsVoicePreset(
    name: '儿童故事',
    voiceId: 'zh-CN-XiaoyiNeural',
    rate: 1.0,
    pitch: 1.02,
    description: '晓伊 · 柔和亲切',
  ),
  TtsVoicePreset(
    name: '男声小说',
    voiceId: 'zh-CN-YunxiNeural',
    rate: 0.98,
    pitch: 1.0,
    description: '云希 · 自然沉稳',
  ),
  TtsVoicePreset(
    name: '知识科普',
    voiceId: 'zh-CN-YunyangNeural',
    rate: 1.0,
    pitch: 1.0,
    description: '云扬 · 吐字清楚',
  ),
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
  void resetCache() {}

  @override
  Future<void> testConnection() async {
    if (fail) throw const TtsException('fake', '测试失败');
  }

  @override
  Future<void> dispose() async {}
}

/// 语音数据占位（引擎内部使用）。
typedef TtsAudioBytes = Uint8List;
