import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:kele_audio/core/api/key_value_store.dart';
import 'package:kele_audio/core/domain/reader_book.dart';
import 'package:kele_audio/core/services/player/media_bridge.dart';
import 'package:kele_audio/core/services/player/playback_arbiter.dart';
import 'package:kele_audio/core/services/reader/book_store.dart';
import 'package:kele_audio/core/services/reader/epub_chapter_text.dart';
import 'package:kele_audio/core/services/reader/reader_activity_store.dart';
import 'package:kele_audio/core/services/reader/reader_bridge.dart';
import 'package:kele_audio/core/services/tts/doubao_cookie_pool.dart';
import 'package:kele_audio/core/services/tts/doubao_tts_client.dart';
import 'package:kele_audio/core/services/tts/tts_engine.dart';
import 'package:kele_audio/core/services/tts/tts_text_splitter.dart';
import 'package:kele_audio/core/services/tts/tts_engine_system.dart';
import 'package:kele_audio/core/services/tts/tts_session.dart';
import 'package:kele_audio/core/services/tts/tts_settings_store.dart';

class _FakePort implements TtsReaderPort {
  _FakePort(this.chapters);

  final List<List<String>> chapters;
  final List<int> highlights = [];
  final List<({int index, int? start, int? end})> marks = [];
  int chapter = 0;
  int visible = 0;
  ReaderSentenceAnchor? anchor;

  /// 这些章的段落抽取模拟 WebView 不可用（锁屏冻结 / 渲染进程被杀）。
  Set<int> unavailableChapters = const {};

  /// 这些章的段落抽取永不返回（模拟息屏期间 WebView eval 挂死）。
  Set<int> hangChapters = const {};

  @override
  Future<int> currentChapter() async => chapter;

  @override
  Future<List<String>> paragraphsOf(int chapterIndex) async {
    chapter = chapterIndex;
    if (hangChapters.contains(chapterIndex)) {
      return Completer<List<String>>().future;
    }
    if (unavailableChapters.contains(chapterIndex)) {
      throw const TtsReaderUnavailableException('WebView 不可用');
    }
    return chapters[chapterIndex];
  }

  @override
  Future<void> highlight(
    int paragraphIndex, {
    bool scroll = true,
    int? startChar,
    int? endChar,
  }) async {
    highlights.add(paragraphIndex);
    marks.add((
      index: paragraphIndex,
      start: startChar,
      end: endChar,
    ));
  }

  @override
  Future<void> clearHighlight() async {}

  @override
  Future<int> visibleParagraph() async => visible;

  @override
  Future<int?> visibleParagraphStrict() async => visible;

  @override
  Future<ReaderSentenceAnchor?> firstVisibleSentence({
    int? expectedChapter,
  }) async =>
      anchor;
}

/// 可控假引擎：`speak` 阻塞到 `stop()`，用于模拟「正在朗读」中切语速。
class _GatedTtsEngine implements TtsEngine {
  _GatedTtsEngine({
    this.deadOnStart = false,
    this.deadOnSpeak = false,
    this.failReload = false,
  });

  /// 首次 start 抛「引擎不可用」（初始化失败用例）。
  final bool deadOnStart;

  /// speak 抛 speak_failed（合成失败用例）。
  final bool deadOnSpeak;

  /// 第二次及以后 start 抛参数错误（切语速失败用例）。
  final bool failReload;

  final List<String> spoken = [];
  final List<TtsParams> startedWith = [];
  Completer<void>? _gate;

  @override
  String get id => 'gated';

  @override
  Future<void> start(TtsParams params) async {
    startedWith.add(params);
    if (deadOnStart && startedWith.length == 1) {
      throw const TtsException('system_unavailable', '系统朗读引擎不可用');
    }
    if (failReload && startedWith.length > 1) {
      throw const TtsException('param_failed', '参数设置失败');
    }
  }

  @override
  void prefetch(String text) {}

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    if (deadOnSpeak) {
      throw const TtsException('speak_failed', '系统朗读暂时无法合成');
    }
    _gate = Completer<void>();
    await _gate!.future;
  }

  @override
  Future<void> stop() async {
    final gate = _gate;
    _gate = null;
    gate?.complete();
  }

  @override
  Future<void> testConnection() async {}

  @override
  void resetCache() {}

  @override
  Future<void> dispose() async {}
}

/// 记录合成与预合成文本，用于验证短句切分与「首片段不预取」。
class _SegmentRecordingEngine implements TtsEngine {
  final List<String> spoken = [];
  final List<String> prefetched = [];

  @override
  String get id => 'recording';

  @override
  Future<void> start(TtsParams params) async {}

  @override
  void prefetch(String text) => prefetched.add(text);

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async {}

  @override
  void resetCache() {}

  @override
  Future<void> testConnection() async {}

  @override
  Future<void> dispose() async {}
}

/// 在指定句子上阻塞，用于验证「切音色时从当前句续读」。
class _BlockOnTextEngine implements TtsEngine {
  _BlockOnTextEngine(this.blockText);

  final String blockText;
  final List<String> spoken = [];
  Completer<void>? _gate;

  @override
  String get id => 'blocking';

  @override
  Future<void> start(TtsParams params) async {}

  @override
  void prefetch(String text) {}

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    if (text == blockText) {
      _gate = Completer<void>();
      await _gate!.future;
    }
  }

  @override
  Future<void> stop() async {
    _gate?.complete();
    _gate = null;
  }

  @override
  void resetCache() {}

  @override
  Future<void> testConnection() async {}

  @override
  Future<void> dispose() async {}
}

ReaderBook _book({int chapterCount = 2}) => ReaderBook(
      id: 'b1',
      title: '测试书',
      source: ReaderBookSource.localEpub,
      fileName: 'book.epub',
      chapterCount: chapterCount,
      addedAt: DateTime(2026, 1, 1),
    );

/// 单测里关掉句间静默：假引擎瞬时返回，否则每句都要多等 0.1~0.5 秒。
Duration _noSegmentGap(String text, {required bool paragraphEnd}) =>
    Duration.zero;

/// 离线正文兜底假件：模拟 EpubChapterText（可切换「书文件不可读」）。
class _FakeChapterText implements TtsChapterTextSource {
  _FakeChapterText(this.chapters);

  final List<List<String>> chapters;
  final List<int> requested = [];
  bool broken = false;

  @override
  Future<List<String>> paragraphsOf(String bookId, int chapterIndex) async {
    requested.add(chapterIndex);
    if (broken) throw StateError('书籍文件不可读');
    if (chapterIndex < 0 || chapterIndex >= chapters.length) return const [];
    return chapters[chapterIndex];
  }
}

void main() {
  test('TtsSettingsStore 持久化引擎/音色/语速', () async {
    final kv = MemoryKeyValueStore();
    final store = TtsSettingsStore(kv);
    await store.load();
    expect(store.engine, TtsEngineKind.edge);

    await store.setEngine(TtsEngineKind.system);
    await store.setEdgeVoice('zh-CN-YunxiNeural');
    await store.setRate(1.5);
    await store.setPitch(0.8);

    final restored = TtsSettingsStore(kv);
    await restored.load();
    expect(restored.engine, TtsEngineKind.system);
    expect(restored.edgeVoice, 'zh-CN-YunxiNeural');
    expect(restored.rate, 1.5);
    expect(restored.pitch, 0.8);
    expect(store.toJson().containsKey('defaultListen'), isFalse);
  });

  test('语速/音调按 0.1 步长量化，可在 1.0 与 0.9 间逐级切换', () async {
    final store = TtsSettingsStore(MemoryKeyValueStore());
    await store.load();

    expect(TtsSettingsStore.quantizeParam(1.0), 1.0);
    expect(TtsSettingsStore.quantizeParam(0.9), closeTo(0.9, 1e-9));
    expect(TtsSettingsStore.quantizeParam(0.94), closeTo(0.9, 1e-9));
    expect(TtsSettingsStore.quantizeParam(1.06), closeTo(1.1, 1e-9));

    await store.setRate(TtsSettingsStore.quantizeParam(0.94));
    await store.setPitch(TtsSettingsStore.quantizeParam(1.06));
    expect(store.rate, closeTo(0.9, 1e-9));
    expect(store.pitch, closeTo(1.1, 1e-9));
  });

  test('旧版 mimo/http 引擎回落 Edge 并清除残留 Key', () async {
    final kv = MemoryKeyValueStore();
    await kv.setString(
      'tts_settings',
      jsonEncode({
        'engine': 'mimo',
        'edgeVoice': 'zh-CN-YunxiNeural',
        'mimoVoice': 'mimo_default',
        'templates': <String>[],
      }),
    );
    await kv.setString('mimo_api_key', 'secret');

    final store = TtsSettingsStore(kv);
    await store.load();
    expect(store.engine, TtsEngineKind.edge);
    expect(store.edgeVoice, 'zh-CN-YunxiNeural');
    expect(kv.getString('mimo_api_key'), isNull);
  });

  test('activeVoice 随引擎切换到对应音色并可持久化', () async {
    final kv = MemoryKeyValueStore();
    final store = TtsSettingsStore(kv);
    await store.load();
    expect(store.activeVoice, 'zh-CN-XiaoxiaoNeural');

    await store.setEdgeVoice('zh-CN-YunxiNeural');
    await store.setSystemVoice('zh-CN-system-voice');
    expect(store.activeVoice, 'zh-CN-YunxiNeural');

    await store.setEngine(TtsEngineKind.system);
    expect(store.activeVoice, 'zh-CN-system-voice');

    final restored = TtsSettingsStore(kv);
    await restored.load();
    expect(restored.engine, TtsEngineKind.system);
    expect(restored.activeVoice, 'zh-CN-system-voice');
  });

  test('豆包 Cookie 轮询池：解析、轮换、风控冷却跳过', () {
    final a = 'sessionid=a; sid_guard=a; uid_tt=a';
    final b = 'sessionid=b; sid_guard=b; uid_tt=b';
    final c = 'sessionid=c; sid_guard=c; uid_tt=c';

    // 换行 / 竖线均可切分，空行忽略；单 Cookie 原样返回。
    expect(DoubaoTtsCookiePool.parse('$a\n$b\n'), [a, b]);
    expect(DoubaoTtsCookiePool.parse('$a|$b'), [a, b]);
    expect(DoubaoTtsCookiePool.parse(a), [a]);

    final pool = DoubaoTtsCookiePool.instance;
    final cookies = [a, b, c];
    pool.reset();
    // 顺序轮换。
    expect(pool.next(cookies), a);
    expect(pool.next(cookies), b);
    expect(pool.next(cookies), c);
    expect(pool.next(cookies), a);

    // b 被风控冷却后，轮询跳过 b。
    pool.reset();
    pool.markFailed(b);
    final picked = <String>[];
    for (var i = 0; i < 6; i++) {
      picked.add(pool.next(cookies)!);
    }
    expect(picked, isNot(contains(b)));
    pool.markSuccess(b);
    pool.reset();
  });

  test('设置载入会重置豆包 Cookie 池与节流，避免备份还原后沿用旧限流态', () async {
    final a = 'sessionid=a; sid_guard=a; uid_tt=a';
    final b = 'sessionid=b; sid_guard=b; uid_tt=b';

    // 制造「旧账号被风控」的残留态：池里 b 冷却、节流退避累加。
    final pool = DoubaoTtsCookiePool.instance;
    pool.reset();
    pool.markFailed(b);
    expect(pool.next([a, b]), a);
    final throttle = DoubaoTtsThrottle.instance;
    throttle.reset();
    throttle.noteFailure();
    throttle.noteFailure();

    // load() 无论来源（启动或备份还原）都应清空这些残留。
    final kv = MemoryKeyValueStore();
    final store = TtsSettingsStore(kv);
    await store.load();

    expect(pool.next([a, b]), a, reason: '冷却应被清除，首个 Cookie 仍是 a');
    // reset 后再连续取，b 不应再被跳过。
    final picked = <String>[];
    for (var i = 0; i < 4; i++) {
      picked.add(pool.next([a, b])!);
    }
    expect(picked, contains(b));
    pool.reset();
    throttle.reset();
  });

  test('豆包批量切分：多句合并后请求数少于逐句切分', () {
    final paragraph = '第一句话内容比较短。第二句话内容也不长。'
        '第三句话继续讲述一些事情。第四句话是最后的内容。'
        '第五句话补充说明一下。第六句话到此结束。';
    final perSentence = const TtsTextSplitter.perSentence().split(paragraph);
    final batched = const TtsTextSplitter.batched().split(paragraph);

    expect(batched.length, lessThan(perSentence.length));
    // 合并片段仍保留原文字符区间，供高亮/续读使用。
    for (final seg in batched) {
      expect(seg.text.isNotEmpty, isTrue);
      expect(seg.start, greaterThanOrEqualTo(0));
      expect(seg.end, greaterThan(seg.start));
    }
    expect(perSentence.length, greaterThan(3));
  });

  test('豆包音色/Cookie 可持久化，activeVoice 随引擎切换', () async {
    final kv = MemoryKeyValueStore();
    final store = TtsSettingsStore(kv);
    await store.load();
    expect(store.doubaoVoice, doubaoDefaultVoiceId);
    expect(store.doubaoCookie, isEmpty);

    await store.setDoubaoVoice('zh_male_ahu_conversation_wvae_bigtts');
    await store.setDoubaoCookie('  sessionid=abc; uid_tt=123  ');
    await store.setEngine(TtsEngineKind.doubao);
    expect(store.activeVoice, 'zh_male_ahu_conversation_wvae_bigtts');
    expect(store.doubaoCookie, 'sessionid=abc; uid_tt=123');

    // Cookie 单独存放，绝不混进普通设置 JSON（备份时该 JSON 走 keys 明文区）。
    expect(store.toJson().containsKey('doubaoCookie'), isFalse);
    expect(
      kv.getString(TtsSettingsStore.doubaoCookieStorageKey),
      'sessionid=abc; uid_tt=123',
    );

    final restored = TtsSettingsStore(kv);
    await restored.load();
    expect(restored.engine, TtsEngineKind.doubao);
    expect(restored.doubaoVoice, 'zh_male_ahu_conversation_wvae_bigtts');
    expect(restored.doubaoCookie, 'sessionid=abc; uid_tt=123');
    expect(restored.activeVoice, 'zh_male_ahu_conversation_wvae_bigtts');
  });

  test('豆包已下线的旧音色 ID 加载时回退当前默认音色', () async {
    final kv = MemoryKeyValueStore();
    await kv.setString(
      'tts_settings',
      jsonEncode({
        'engine': 'doubao',
        // 2025 年初的旧音色 ID，已被豆包下线：服务端对未知 speaker 静默
        // 回退默认女声，客户端必须在加载时把它纠正到当前有效清单。
        'doubaoVoice': 'zh_male_chenwen_moon_bigtts',
      }),
    );

    final store = TtsSettingsStore(kv);
    await store.load();
    expect(store.doubaoVoice, doubaoDefaultVoiceId);
  });

  test('旧版内嵌 doubaoCookie 迁移到独立 key 并从设置 JSON 擦除', () async {
    final kv = MemoryKeyValueStore();
    await kv.setString(
      'tts_settings',
      jsonEncode({
        'engine': 'doubao',
        'doubaoVoice': 'zh_male_chenwen_moon_bigtts',
        'doubaoCookie': 'sessionid=legacy',
      }),
    );

    final store = TtsSettingsStore(kv);
    await store.load();

    expect(store.doubaoCookie, 'sessionid=legacy');
    expect(
      kv.getString(TtsSettingsStore.doubaoCookieStorageKey),
      'sessionid=legacy',
    );
    final plain = jsonDecode(kv.getString('tts_settings')!) as Map;
    expect(plain.containsKey('doubaoCookie'), isFalse);
    expect(plain['engine'], 'doubao');
  });

  test('清空豆包 Cookie 会删除独立凭据 key', () async {
    final kv = MemoryKeyValueStore();
    final store = TtsSettingsStore(kv);
    await store.load();
    await store.setDoubaoCookie('sessionid=abc');
    expect(kv.getString(TtsSettingsStore.doubaoCookieStorageKey), isNotNull);

    await store.setDoubaoCookie('   ');
    expect(store.doubaoCookie, isEmpty);
    expect(kv.getString(TtsSettingsStore.doubaoCookieStorageKey), isNull);
  });

  test('豆包音色清单默认音色与常量一致', () {
    final ids = doubaoZhVoices.map((v) => v.id).toSet();
    expect(ids, contains(doubaoDefaultVoiceId));
    expect(doubaoZhVoices.first.id, doubaoDefaultVoiceId);
  });

  group('豆包 WAV 流容器头剥离', () {
    // 构造流式 WAV：RIFF + fmt + data（size 占位 0xFFFFFFFF）+ PCM。
    Uint8List streamingWav(List<int> pcm, {int headerRiffSize = 0xFFFFFFFF}) {
      Uint8List u32(int v) => (ByteData(4)..setUint32(0, v, Endian.little))
          .buffer
          .asUint8List();
      final fmt = Uint8List(16)
        ..buffer.asByteData().setUint16(0, 1, Endian.little) // PCM
        ..buffer.asByteData().setUint16(2, 1, Endian.little) // mono
        ..buffer.asByteData().setUint32(4, 24000, Endian.little) // rate
        ..buffer.asByteData().setUint32(8, 48000, Endian.little) // byte rate
        ..buffer.asByteData().setUint16(12, 2, Endian.little) // block align
        ..buffer.asByteData().setUint16(14, 16, Endian.little); // bits

      final b = BytesBuilder()
        ..add('RIFF'.codeUnits)
        ..add(u32(headerRiffSize))
        ..add('WAVE'.codeUnits)
        ..add('fmt '.codeUnits)
        ..add(u32(16))
        ..add(fmt)
        ..add('data'.codeUnits)
        ..add(u32(0xFFFFFFFF))
        ..add(pcm);
      return b.toBytes();
    }

    Uint8List headerBlock() => streamingWav(const []);

    test('流中无中途容器头时原样返回', () {
      final pcm = List<int>.generate(1000, (i) => i & 0xFF);
      final wav = streamingWav(pcm);
      final out = DoubaoTtsClient.stripEmbeddedWavHeaders(wav);
      expect(out.length, wav.length);
      expect(String.fromCharCodes(out.sublist(0, 4)), 'RIFF');
    });

    test('句界重发的容器头被剥离，PCM 原样保留', () {
      final pcmA = List<int>.generate(400, (i) => i & 0x7F);
      final pcmB = List<int>.generate(600, (i) => (i * 7) & 0x7F);
      final wav = streamingWav(pcmA);
      final header = headerBlock();
      final combined = BytesBuilder()
        ..add(wav)
        ..add(header) // 句界重发
        ..add(pcmB);
      final out = DoubaoTtsClient.stripEmbeddedWavHeaders(combined.toBytes());

      final expectLen = wav.length + pcmB.length;
      expect(out.length, expectLen);
      // 头部（含首个流式头）与段 A 完整保留。
      final head = BytesBuilder()..add(wav);
      expect(
        out.sublist(0, head.length),
        head.toBytes(),
      );
      // 段 B 紧跟其后且逐字节一致。
      expect(out.sublist(head.length), Uint8List.fromList(pcmB));
    });

    test('PCM 中偶然出现的 RIFF 序列（非法头）不误删', () {
      final pcmA = List<int>.generate(300, (i) => i & 0x7F);
      // 恰好是「RIFF」四个字符，但后面不是合法 WAVE/fmt 结构。
      final fake = 'RIFFGarbage'.codeUnits;
      final pcmB = List<int>.generate(200, (i) => (i + 3) & 0x7F);
      final combined = BytesBuilder()
        ..add(streamingWav(pcmA))
        ..add(fake)
        ..add(pcmB);
      final raw = combined.toBytes();
      final out = DoubaoTtsClient.stripEmbeddedWavHeaders(raw);
      expect(out.length, raw.length);
    });

    test('偏移 0 的首个头永远保留', () {
      final pcm = List<int>.generate(100, (i) => i & 0x7F);
      final wav = streamingWav(pcm);
      final out = DoubaoTtsClient.stripEmbeddedWavHeaders(wav);
      expect(out.length, wav.length);
    });
  });

  test('Edge 音色清单覆盖全部听书预设，默认音色未被改动', () {
    final ids = edgeZhVoices.map((v) => v.id).toSet();
    expect(ids, contains('zh-CN-XiaoxiaoNeural'));
    for (final preset in edgeVoicePresets) {
      expect(ids, contains(preset.voiceId), reason: preset.name);
    }
    expect(edgeVoicePresets.first.voiceId, 'zh-CN-XiaoxiaoNeural');
    expect(edgeVoicePresets.first.rate, 1.0);
    expect(edgeVoicePresets.first.pitch, 1.0);
    expect(
      edgeVoicePresets.first.matches(
        voice: 'zh-CN-XiaoxiaoNeural',
        rate: 1.0,
        pitch: 1.0,
      ),
      isTrue,
    );
  });

  test('applyVoicePreset 一次性写入音色、语速和音调', () async {
    final kv = MemoryKeyValueStore();
    final store = TtsSettingsStore(kv);
    await store.load();

    final preset = edgeVoicePresets.firstWhere(
      (p) => p.name == '儿童故事',
    );
    await store.applyVoicePreset(preset);

    expect(store.edgeVoice, 'zh-CN-XiaoyiNeural');
    expect(store.rate, 1.0);
    expect(store.pitch, 1.02);

    final restored = TtsSettingsStore(kv);
    await restored.load();
    expect(restored.edgeVoice, 'zh-CN-XiaoyiNeural');
    expect(restored.pitch, 1.02);
  });

  test('PlaybackArbiter：B 站与 TTS 互斥且切换媒体回调', () async {
    final media = NoopMediaBridge();
    final arbiter = PlaybackArbiter(media: media);
    var biliStopped = 0;
    var ttsStopped = 0;
    var ttsBound = 0;
    var biliBound = 0;

    arbiter.registerBili(
      bind: () => biliBound++,
      bindFocus: () {},
      stop: () async => biliStopped++,
      publish: () {},
    );
    arbiter.registerTts(
      bind: () => ttsBound++,
      bindFocus: () {},
      stop: () async => ttsStopped++,
    );

    await arbiter.claimTts();
    expect(arbiter.owner, PlaybackOwner.tts);
    expect(ttsBound, 1);

    await arbiter.claimBili();
    expect(ttsStopped, 1);
    expect(arbiter.owner, PlaybackOwner.bili);
    expect(biliBound, 1);

    arbiter.releaseTts();
    expect(arbiter.owner, PlaybackOwner.bili);
  });

  test('TtsSession：逐段朗读、跨章续读、断点落盘且不写听书历史', () async {
    final kv = MemoryKeyValueStore();
    final settings = TtsSettingsStore(kv);
    await settings.load();
    await settings.setEngine(TtsEngineKind.system);

    final books = ReaderBookStore(kv);
    await books.add(_book());
    final activity = ReaderActivityStore(kv);
    await activity.load();

    final media = NoopMediaBridge();
    final arbiter = PlaybackArbiter(media: media);
    final engine = FakeTtsEngine();
    final session = TtsSession(
      settings: settings,
      books: books,
      activity: activity,
      arbiter: arbiter,
      engineFactory: (_) => engine,
    );
    final port = _FakePort([
      ['第一段', '第二段'],
      ['第三章甲', '第三章乙'],
    ]);
    session.bindReader(
      book: books.byId('b1')!,
      port: port,
      chapterTitleOf: (i) => '第${i + 1}章',
    );

    await session.start(chapterIndex: 0, paraIndex: 0, fromBookmark: false);
    // 假引擎瞬时完成：等待两章共 4 段跑完。
    for (var i = 0; i < 40 && session.active; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(engine.spoken, ['第一段', '第二段', '第三章甲', '第三章乙']);
    expect(port.highlights, [0, 1, 0, 1]);
    expect(session.active, isFalse);

    final saved = books.byId('b1')!;
    expect(saved.lastChapterIndex, 1);
    expect(saved.lastTtsParaIndex, 1);

    // 本地听书不写入历史记录（统计时长仍走独立的 logDuration）。
    final listening = activity.history
        .where((e) => e.mode == ReaderActivityMode.listening)
        .toList();
    expect(listening, isEmpty);
  });

  test('空章（只有单行数字页码）跳过并续读下一章，不卡住', () async {
    final kv = MemoryKeyValueStore();
    final settings = TtsSettingsStore(kv);
    await settings.load();
    await settings.setEngine(TtsEngineKind.system);
    final books = ReaderBookStore(kv);
    await books.add(_book());
    final activity = ReaderActivityStore(kv);
    await activity.load();
    final engine = FakeTtsEngine();
    final session = TtsSession(
      settings: settings,
      books: books,
      activity: activity,
      arbiter: PlaybackArbiter(media: NoopMediaBridge()),
      engineFactory: (_) => engine,
    );
    final port = _FakePort([
      const [], // 本章正文只有一个单行数字，被抽取层过滤掉
      ['第二章正文'],
    ]);
    session.bindReader(
      book: books.byId('b1')!,
      port: port,
      chapterTitleOf: (i) => '第${i + 1}章',
    );

    await session.start(chapterIndex: 0, paraIndex: 0, fromBookmark: false);
    for (var i = 0; i < 40 && session.active; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(session.error, isNull);
    expect(engine.spoken, ['第二章正文']);
    expect(session.chapterIndex, 1);
    expect(session.active, isFalse);
  });

  test('WebView 不可用时暂停在当前章，绝不按空章连跳写坏断点', () async {
    // 复现线上「54 章读完 → 锁屏 → 回来已在 76 章」：
    // 锁屏期间 WebView 冻结，旧实现把抽取超时当「空章」逐章连跳并落盘断点。
    final kv = MemoryKeyValueStore();
    final settings = TtsSettingsStore(kv);
    await settings.load();
    await settings.setEngine(TtsEngineKind.system);
    final books = ReaderBookStore(kv);
    await books.add(_book());
    final activity = ReaderActivityStore(kv);
    await activity.load();
    final engine = FakeTtsEngine();
    final session = TtsSession(
      settings: settings,
      books: books,
      activity: activity,
      arbiter: PlaybackArbiter(media: NoopMediaBridge()),
      engineFactory: (_) => engine,
    );
    final port = _FakePort([
      ['第一段', '第二段'],
      ['第二章甲', '第二章乙'],
      ['第三章甲', '第三章乙'],
    ]);
    // 第 2 章（下标 1）抽取不可用，模拟换章后 WebView 被冻结。
    port.unavailableChapters = {1};
    session.bindReader(
      book: books.byId('b1')!,
      port: port,
      chapterTitleOf: (i) => '第${i + 1}章',
    );

    await session.start(chapterIndex: 0, paraIndex: 0, fromBookmark: false);
    for (var i = 0; i < 60 && !session.paused; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    // 第 1 章正常读完，随后应暂停在第 2 章等待 WebView 恢复，
    // 既不报错弹红字，也绝不跳到第 3 章或直接整轮结束。
    expect(engine.spoken, ['第一段', '第二段']);
    expect(session.error, isNull);
    expect(session.active, isTrue);
    expect(session.paused, isTrue);
    expect(session.playing, isFalse);
    expect(session.chapterIndex, 1);
    expect(books.byId('b1')!.lastChapterIndex, 1);
    expect(books.byId('b1')!.lastTtsParaIndex, 0);

    // WebView 恢复后（阅读页回到前台），resume 从第 2 章段首续读。
    port.unavailableChapters = const {};
    await session.resume();
    for (var i = 0; i < 60 && engine.spoken.length < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(engine.spoken, ['第一段', '第二段', '第二章甲', '第二章乙']);
    expect(session.chapterIndex, 1);
    await session.stop();
    expect(session.active, isFalse);
  });

  test('息屏跨章：WebView 冻结时离线兜底续读，不再停在章边界', () async {
    final kv = MemoryKeyValueStore();
    final settings = TtsSettingsStore(kv);
    await settings.load();
    await settings.setEngine(TtsEngineKind.system);
    final books = ReaderBookStore(kv);
    await books.add(_book(chapterCount: 3));
    final activity = ReaderActivityStore(kv);
    await activity.load();
    final engine = FakeTtsEngine();
    final fallback = _FakeChapterText([
      ['第一段', '第二段'],
      ['第二章甲', '第二章乙'],
      ['第三章甲', '第三章乙'],
    ]);
    final session = TtsSession(
      settings: settings,
      books: books,
      activity: activity,
      arbiter: PlaybackArbiter(media: NoopMediaBridge()),
      engineFactory: (_) => engine,
      fallbackText: fallback,
      portFetchTimeout: const Duration(milliseconds: 100),
    );
    final port = _FakePort([
      ['第一段', '第二段'],
      ['第二章甲', '第二章乙'],
      ['第三章甲', '第三章乙'],
    ]);
    // 第 2 章起 WebView 冻结（锁屏），逐章抽取都不可用。
    port.unavailableChapters = {1, 2};
    session.bindReader(
      book: books.byId('b1')!,
      port: port,
      chapterTitleOf: (i) => '第${i + 1}章',
    );

    await session.start(chapterIndex: 0, paraIndex: 0, fromBookmark: false);
    for (var i = 0; i < 60 && session.active; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    // 息屏后跨章不再停住：第 2/3 章直接从离线正文续读，整轮读完。
    expect(session.error, isNull);
    expect(engine.spoken, [
      '第一段',
      '第二段',
      '第二章甲',
      '第二章乙',
      '第三章甲',
      '第三章乙',
    ]);
    expect(fallback.requested, [1, 2]);
    expect(session.active, isFalse);
    expect(books.byId('b1')!.lastChapterIndex, 2);
    expect(books.byId('b1')!.lastTtsParaIndex, 1);
  });

  test('息屏 WebView eval 挂死时取段超时转离线兜底续读', () async {
    final kv = MemoryKeyValueStore();
    final settings = TtsSettingsStore(kv);
    await settings.load();
    await settings.setEngine(TtsEngineKind.system);
    final books = ReaderBookStore(kv);
    await books.add(_book());
    final activity = ReaderActivityStore(kv);
    await activity.load();
    final engine = FakeTtsEngine();
    final fallback = _FakeChapterText([
      ['第一段', '第二段'],
      ['第二章甲', '第二章乙'],
    ]);
    final session = TtsSession(
      settings: settings,
      books: books,
      activity: activity,
      arbiter: PlaybackArbiter(media: NoopMediaBridge()),
      engineFactory: (_) => engine,
      fallbackText: fallback,
      portFetchTimeout: const Duration(milliseconds: 100),
    );
    final port = _FakePort([
      ['第一段', '第二段'],
      ['第二章甲', '第二章乙'],
    ]);
    // 第 2 章抽取永不返回：模拟息屏期间 WebView eval 挂死（旧实现会永远停住）。
    port.hangChapters = {1};
    session.bindReader(
      book: books.byId('b1')!,
      port: port,
      chapterTitleOf: (i) => '第${i + 1}章',
    );

    await session.start(chapterIndex: 0, paraIndex: 0, fromBookmark: false);
    for (var i = 0; i < 80 && session.active; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(session.error, isNull);
    expect(engine.spoken, ['第一段', '第二段', '第二章甲', '第二章乙']);
    expect(fallback.requested, [1]);
    expect(session.active, isFalse);
  });

  test('离线兜底也不可用时仍暂停在当前章等待恢复', () async {
    final kv = MemoryKeyValueStore();
    final settings = TtsSettingsStore(kv);
    await settings.load();
    await settings.setEngine(TtsEngineKind.system);
    final books = ReaderBookStore(kv);
    await books.add(_book());
    final activity = ReaderActivityStore(kv);
    await activity.load();
    final engine = FakeTtsEngine();
    final fallback = _FakeChapterText([
      ['第二章甲', '第二章乙'],
    ])
      ..broken = true;
    final session = TtsSession(
      settings: settings,
      books: books,
      activity: activity,
      arbiter: PlaybackArbiter(media: NoopMediaBridge()),
      engineFactory: (_) => engine,
      fallbackText: fallback,
    );
    final port = _FakePort([
      ['第一段', '第二段'],
      ['第二章甲', '第二章乙'],
    ]);
    port.unavailableChapters = {1};
    session.bindReader(
      book: books.byId('b1')!,
      port: port,
      chapterTitleOf: (i) => '第${i + 1}章',
    );

    await session.start(chapterIndex: 0, paraIndex: 0, fromBookmark: false);
    for (var i = 0; i < 60 && !session.paused; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    // 兜底源损坏（书文件缺失等）时退回旧语义：暂停在第 2 章等恢复，不误跳。
    expect(engine.spoken, ['第一段', '第二段']);
    expect(session.error, isNull);
    expect(session.paused, isTrue);
    expect(session.chapterIndex, 1);
    expect(books.byId('b1')!.lastChapterIndex, 1);
  });

  test('关闭阅读页后离线兜底继续跨章续读（含跨章边界）', () async {
    final kv = MemoryKeyValueStore();
    final settings = TtsSettingsStore(kv);
    await settings.load();
    await settings.setEngine(TtsEngineKind.system);
    final books = ReaderBookStore(kv);
    await books.add(_book(chapterCount: 3));
    final activity = ReaderActivityStore(kv);
    await activity.load();
    final engine = FakeTtsEngine();
    final fallback = _FakeChapterText([
      ['第一段', '第二段'],
      ['第二章甲', '第二章乙'],
      ['第三章甲', '第三章乙'],
    ])
      ..broken = true;
    final session = TtsSession(
      settings: settings,
      books: books,
      activity: activity,
      arbiter: PlaybackArbiter(media: NoopMediaBridge()),
      engineFactory: (_) => engine,
      fallbackText: fallback,
      portFetchTimeout: const Duration(milliseconds: 100),
    );
    final port = _FakePort([
      ['第一段', '第二段'],
      ['第二章甲', '第二章乙'],
      ['第三章甲', '第三章乙'],
    ]);
    port.unavailableChapters = {1, 2};
    session.bindReader(
      book: books.byId('b1')!,
      port: port,
      chapterTitleOf: (i) => '第${i + 1}章',
    );

    await session.start(chapterIndex: 0, paraIndex: 0, fromBookmark: false);
    for (var i = 0; i < 60 && !session.paused; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(engine.spoken, ['第一段', '第二段']);
    expect(session.paused, isTrue);

    // 关闭阅读页后恢复播放：新章正文走离线兜底，跨章边界也不再要求回阅读页。
    fallback.broken = false;
    session.unbindReader();
    await session.resume();
    for (var i = 0; i < 80 && session.active; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(session.error, isNull);
    expect(engine.spoken, [
      '第一段',
      '第二段',
      '第二章甲',
      '第二章乙',
      '第三章甲',
      '第三章乙',
    ]);
    expect(session.active, isFalse);
  });

  test('WebView 误判空章时以离线正文为准，不跳过真章', () async {
    final kv = MemoryKeyValueStore();
    final settings = TtsSettingsStore(kv);
    await settings.load();
    await settings.setEngine(TtsEngineKind.system);
    final books = ReaderBookStore(kv);
    await books.add(_book());
    final activity = ReaderActivityStore(kv);
    await activity.load();
    final engine = FakeTtsEngine();
    final fallback = _FakeChapterText([
      ['第一章甲', '第一章乙'],
      ['第二章正文'],
    ]);
    final session = TtsSession(
      settings: settings,
      books: books,
      activity: activity,
      arbiter: PlaybackArbiter(media: NoopMediaBridge()),
      engineFactory: (_) => engine,
      fallbackText: fallback,
    );
    final port = _FakePort([
      const [], // 换章过渡期误判空章
      ['第二章正文'],
    ]);
    session.bindReader(
      book: books.byId('b1')!,
      port: port,
      chapterTitleOf: (i) => '第${i + 1}章',
    );

    await session.start(chapterIndex: 0, paraIndex: 0, fromBookmark: false);
    for (var i = 0; i < 60 && session.active; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(engine.spoken, ['第一章甲', '第一章乙', '第二章正文']);
    expect(fallback.requested, [0]);
    expect(session.active, isFalse);
  });

  test('章末纯数字段落被跳过，继续朗读并跨到下一章', () async {
    final kv = MemoryKeyValueStore();
    final settings = TtsSettingsStore(kv);
    await settings.load();
    await settings.setEngine(TtsEngineKind.system);
    final books = ReaderBookStore(kv);
    await books.add(_book());
    final activity = ReaderActivityStore(kv);
    await activity.load();
    final engine = FakeTtsEngine();
    final session = TtsSession(
      settings: settings,
      books: books,
      activity: activity,
      arbiter: PlaybackArbiter(media: NoopMediaBridge()),
      engineFactory: (_) => engine,
    );
    final port = _FakePort([
      ['第一章正文', '12'],
      ['第二章正文'],
    ]);
    session.bindReader(
      book: books.byId('b1')!,
      port: port,
      chapterTitleOf: (i) => '第${i + 1}章',
    );

    await session.start(chapterIndex: 0, paraIndex: 0, fromBookmark: false);
    for (var i = 0; i < 40 && session.active; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(session.error, isNull);
    expect(engine.spoken, ['第一章正文', '第二章正文']);
    expect(session.active, isFalse);
  });

  test('长段落按短句合成：首句不预取，高亮带段内区间', () async {
    final kv = MemoryKeyValueStore();
    final settings = TtsSettingsStore(kv);
    await settings.load();
    final books = ReaderBookStore(kv);
    await books.add(_book());
    final activity = ReaderActivityStore(kv);
    await activity.load();
    final port = _FakePort([
      ['桥头下着雨。风很大，他走进巷子。远处传来钟声。', '第二段'],
      ['第三章甲', '第三章乙'],
    ]);
    final engine = _SegmentRecordingEngine();
    final session = TtsSession(
      settings: settings,
      books: books,
      activity: activity,
      arbiter: PlaybackArbiter(media: NoopMediaBridge()),
      engineFactory: (_) => engine,
      segmentGap: _noSegmentGap,
    );
    session.bindReader(
      book: books.byId('b1')!,
      port: port,
      chapterTitleOf: (i) => '第${i + 1}章',
    );
    await session.start(chapterIndex: 0, paraIndex: 0, fromBookmark: false);
    for (var i = 0; i < 40 && session.active; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    // 朗读会话按「一句一片段」切分：标点即句界，续读可精确到当前句。
    expect(engine.spoken.first, '桥头下着雨。');
    expect(engine.spoken, contains('风很大，他走进巷子。'));
    expect(engine.spoken, contains('远处传来钟声。'));
    expect(engine.spoken.length, greaterThan(4));
    // 首请求独占合成通道，不被第二句预取抢占。
    expect(engine.prefetched, isNot(contains(engine.spoken.first)));
    // 同一段落内的两个短句分别高亮到不同字符区间。
    expect(port.marks.first.index, 0);
    expect(port.marks.first.start, 0);
    expect(port.marks.first.end, engine.spoken.first.length);
    expect(port.marks[1].index, 0);
    expect(port.marks[1].start, greaterThan(0));
  });

  test('指定句锚点起播：从当前页第一句开始，跳过同段前面的句子', () async {
    final kv = MemoryKeyValueStore();
    final settings = TtsSettingsStore(kv);
    await settings.load();
    final books = ReaderBookStore(kv);
    await books.add(_book());
    final activity = ReaderActivityStore(kv);
    await activity.load();
    final port = _FakePort([
      ['甲。乙。丙。丁。'],
      ['下一章。'],
    ]);
    // 「丙。」在段内的起始下标。
    port.anchor = const ReaderSentenceAnchor(paragraph: 0, charIndex: 4);
    final engine = _SegmentRecordingEngine();
    final session = TtsSession(
      settings: settings,
      books: books,
      activity: activity,
      arbiter: PlaybackArbiter(media: NoopMediaBridge()),
      engineFactory: (_) => engine,
      segmentGap: _noSegmentGap,
    );
    session.bindReader(
      book: books.byId('b1')!,
      port: port,
      chapterTitleOf: (i) => '第${i + 1}章',
    );
    await session.start(
      chapterIndex: 0,
      paraIndex: 0,
      charIndex: 4,
      fromBookmark: false,
    );
    for (var i = 0; i < 40 && session.active; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(engine.spoken, ['丙。', '丁。', '下一章。']);
    expect(port.marks.first.start, 4);
  });

  test('自动跨章后句锚点不残留：新章从段首朗读并高亮', () async {
    final kv = MemoryKeyValueStore();
    final settings = TtsSettingsStore(kv);
    await settings.load();
    await settings.setEngine(TtsEngineKind.system);
    final books = ReaderBookStore(kv);
    await books.add(_book());
    final activity = ReaderActivityStore(kv);
    await activity.load();
    final port = _FakePort([
      ['甲。乙。丙。丁。'],
      ['新章甲。新章乙。新章丙。新章丁。'],
    ]);
    final engine = _SegmentRecordingEngine();
    final session = TtsSession(
      settings: settings,
      books: books,
      activity: activity,
      arbiter: PlaybackArbiter(media: NoopMediaBridge()),
      engineFactory: (_) => engine,
      segmentGap: _noSegmentGap,
    );
    session.bindReader(
      book: books.byId('b1')!,
      port: port,
      chapterTitleOf: (i) => '第${i + 1}章',
    );

    // 从「丁。」起播，段内锚点为 6；旧实现跨章后仍拿 6 跳过新章开头两句。
    await session.start(
      chapterIndex: 0,
      paraIndex: 0,
      charIndex: 6,
      fromBookmark: false,
    );
    for (var i = 0; i < 60 && session.active; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(session.error, isNull);
    expect(
      engine.spoken,
      ['丁。', '新章甲。', '新章乙。', '新章丙。', '新章丁。'],
    );
    expect(
      port.marks.map((m) => m.start).toList(),
      [6, 0, 4, 8, 12],
    );
  });

  test('切音色后从当前句续读，不退回段落开头', () async {
    final kv = MemoryKeyValueStore();
    final settings = TtsSettingsStore(kv);
    await settings.load();
    final books = ReaderBookStore(kv);
    await books.add(_book());
    final activity = ReaderActivityStore(kv);
    await activity.load();
    final port = _FakePort([
      ['甲。乙。丙。丁。'],
      ['下一章。'],
    ]);
    final engine = _BlockOnTextEngine('丙。');
    final session = TtsSession(
      settings: settings,
      books: books,
      activity: activity,
      arbiter: PlaybackArbiter(media: NoopMediaBridge()),
      engineFactory: (_) => engine,
      segmentGap: _noSegmentGap,
    );
    session.bindReader(
      book: books.byId('b1')!,
      port: port,
      chapterTitleOf: (i) => '第${i + 1}章',
    );
    await session.start(chapterIndex: 0, paraIndex: 0, fromBookmark: false);
    for (var i = 0; i < 40 && !engine.spoken.contains('丙。'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(engine.spoken, contains('丙。'));

    final before = List<String>.from(engine.spoken);
    await settings.setEdgeVoice('zh-CN-YunxiNeural');
    await session.reloadParams();
    for (var i = 0; i < 40 && engine.spoken.length <= before.length; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(engine.spoken.length, greaterThan(before.length));
    // 重开一轮朗读的第一句仍是「丙。」而非段落首句「甲。」。
    expect(engine.spoken[before.length], '丙。');
    await session.stop();
  });

  test('暂停后按播放：同段内沿用当前句锚点，不退回整段开头', () async {
    final kv = MemoryKeyValueStore();
    final settings = TtsSettingsStore(kv);
    await settings.load();
    await settings.setEngine(TtsEngineKind.system);
    final books = ReaderBookStore(kv);
    await books.add(_book());
    final activity = ReaderActivityStore(kv);
    await activity.load();
    final port = _FakePort([
      ['甲。乙。丙。丁。'],
      ['下一章。'],
    ]);
    // 暂停时阅读页上报的可见句是「本段第一句」（段首）。
    port.anchor = const ReaderSentenceAnchor(paragraph: 0, charIndex: 0);
    final engine = _BlockOnTextEngine('丙。');
    final session = TtsSession(
      settings: settings,
      books: books,
      activity: activity,
      arbiter: PlaybackArbiter(media: NoopMediaBridge()),
      engineFactory: (_) => engine,
      segmentGap: _noSegmentGap,
    );
    session.bindReader(
      book: books.byId('b1')!,
      port: port,
      chapterTitleOf: (i) => '第${i + 1}章',
    );
    await session.start(chapterIndex: 0, paraIndex: 0, fromBookmark: false);
    for (var i = 0; i < 40 && !engine.spoken.contains('丙。'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(engine.spoken, contains('丙。'));

    await session.pause();
    expect(session.paused, isTrue);
    final before = engine.spoken.length;

    // 控制条/顶栏播放键都走 resumeFromView：先按可见句对齐，再恢复。
    await session.resumeFromView();
    for (var i = 0; i < 40 && engine.spoken.length <= before; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    // 从「丙。」这句续读，而不是段落开头「甲。」重念。
    expect(engine.spoken[before], '丙。');
    await session.stop();
  });

  test('句间静默：按标点停顿，下一句不抢上一句尾音', () async {
    // 纯函数部分：标点决定停顿长度，收尾引号不影响判定。
    expect(
      defaultTtsSegmentGap('他走了。', paragraphEnd: false),
      ttsGapStrong,
    );
    expect(
      defaultTtsSegmentGap('他说：走了。”', paragraphEnd: false),
      ttsGapStrong,
    );
    expect(
      defaultTtsSegmentGap('他走了；', paragraphEnd: false),
      ttsGapMedium,
    );
    expect(
      defaultTtsSegmentGap('他走了，', paragraphEnd: false),
      ttsGapWeak,
    );
    // 超长句在逗号处硬切之后若没有标点，必须连读，不能被切碎。
    expect(
      defaultTtsSegmentGap('他走进巷子没有标点', paragraphEnd: false),
      Duration.zero,
    );
    expect(
      defaultTtsSegmentGap('他走了。', paragraphEnd: true),
      ttsGapStrong + ttsGapParagraphExtra,
    );

    // 会话行为：瞬时引擎下第二句仍要等上一句的停顿结束才开口。
    final kv = MemoryKeyValueStore();
    final settings = TtsSettingsStore(kv);
    await settings.load();
    await settings.setEngine(TtsEngineKind.system);
    final books = ReaderBookStore(kv);
    await books.add(_book(chapterCount: 1));
    final activity = ReaderActivityStore(kv);
    await activity.load();
    final port = _FakePort([
      ['甲。乙。'],
    ]);
    final engine = _SegmentRecordingEngine();
    final session = TtsSession(
      settings: settings,
      books: books,
      activity: activity,
      arbiter: PlaybackArbiter(media: NoopMediaBridge()),
      engineFactory: (_) => engine,
    );
    session.bindReader(
      book: books.byId('b1')!,
      port: port,
      chapterTitleOf: (i) => '第${i + 1}章',
    );
    await session.start(chapterIndex: 0, paraIndex: 0, fromBookmark: false);

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(engine.spoken, ['甲。']);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(engine.spoken, contains('乙。'));
    await session.stop();
  });

  group('系统引擎语速映射', () {
    test('默认档 1.0x 映射为正常语速', () {
      expect(TtsSystemEngine.androidRateFor(1.0), 1.0);
    });

    test('最低档 0.5x 映射为半速（明显更慢）', () {
      expect(TtsSystemEngine.androidRateFor(0.5), 0.5);
    });

    test('最高档 3.0x 限速到 1.8x，避免听不清', () {
      expect(TtsSystemEngine.androidRateFor(3.0), 1.8);
    });
  });

  group('系统引擎朗读中切语速', () {
    Future<TtsSession> build(
      TtsSettingsStore settings,
      TtsEngine engine, {
      _FakePort? port,
    }) async {
      final kv = MemoryKeyValueStore();
      await settings.load();
      await settings.setEngine(TtsEngineKind.system);
      final books = ReaderBookStore(kv);
      await books.add(_book());
      final activity = ReaderActivityStore(kv);
      await activity.load();
      final session = TtsSession(
        settings: settings,
        books: books,
        activity: activity,
        arbiter: PlaybackArbiter(media: NoopMediaBridge()),
        engineFactory: (_) => engine,
      );
      session.bindReader(
        book: books.byId('b1')!,
        port: port ??
            _FakePort([
              ['第一段', '第二段'],
              ['第三章甲', '第三章乙'],
            ]),
        chapterTitleOf: (i) => '第${i + 1}章',
      );
      return session;
    }

    test('不抛异常、不回错误态，按当前段续读，pause 仍有效', () async {
      final settings = TtsSettingsStore(MemoryKeyValueStore());
      final engine = _GatedTtsEngine();
      final session = await build(settings, engine);

      await session.start(chapterIndex: 0, paraIndex: 0, fromBookmark: false);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(engine.spoken, ['第一段']);
      expect(session.playing, isTrue);
      expect(session.error, isNull);

      await settings.setRate(1.25);
      await session.reloadParams(); // 不得抛出

      expect(session.error, isNull);
      expect(session.active, isTrue);
      expect(engine.startedWith.last.rate, 1.25);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // 从当前段重新按新速率朗读，不跳段、不重复下一段。
      expect(engine.spoken, ['第一段', '第一段']);
      expect(session.paragraphIndex, 0);

      await session.pause();
      expect(session.paused, isTrue);
      expect(session.playing, isFalse);
      await session.stop();
      expect(session.active, isFalse);
    });

    test('暂停后翻页再点播放：从当前可见段恢复，不用旧断点', () async {
      final settings = TtsSettingsStore(MemoryKeyValueStore());
      final engine = _GatedTtsEngine();
      final port = _FakePort([
        ['第一段', '第二段'],
        ['第三章甲', '第三章乙'],
      ]);
      final session = await build(settings, engine, port: port);

      await session.start(chapterIndex: 0, paraIndex: 0, fromBookmark: false);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(engine.spoken, ['第一段']);

      await session.pause();
      // 模拟用户暂停后翻到本页第二段，再点控制条播放键。
      port.visible = 1;
      await session.toggle();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(engine.spoken, ['第一段', '第二段']);
      expect(session.paragraphIndex, 1);
      await session.stop();
    });

    test('进度条拖动：预览不发声，松手只从目标段续读一次', () async {
      final settings = TtsSettingsStore(MemoryKeyValueStore());
      final engine = _GatedTtsEngine();
      final session = await build(settings, engine);

      await session.start(chapterIndex: 0, paraIndex: 0, fromBookmark: false);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(engine.spoken, ['第一段']);

      await session.beginSeek();
      expect(session.seeking, isTrue);
      expect(session.playing, isFalse);

      await session.previewSeekToParagraph(1);
      expect(session.paragraphIndex, 1);
      expect(engine.spoken, ['第一段']); // 拖动过程中不得重复朗读

      await session.commitSeek();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(session.seeking, isFalse);
      expect(engine.spoken, ['第一段', '第二段']);
      expect(session.paragraphIndex, 1);
      await session.stop();
    });

    test('参数设置失败时静默降级，不中断朗读', () async {
      final settings = TtsSettingsStore(MemoryKeyValueStore());
      final engine = _GatedTtsEngine(failReload: true);
      final session = await build(settings, engine);

      await session.start(chapterIndex: 0, paraIndex: 0, fromBookmark: false);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(session.playing, isTrue);

      await settings.setRate(1.5);
      await session.reloadParams(); // 参数失败不得抛出、不得弹红字

      expect(session.error, isNull);
      expect(session.active, isTrue);
      expect(session.playing, isTrue);
      expect(session.paragraphIndex, 0);

      await session.pause();
      expect(session.paused, isTrue);
      await session.stop();
    });

    test('合成返回失败（speak_failed）：静默暂停、不弹红字，pause/stop 可用', () async {
      final settings = TtsSettingsStore(MemoryKeyValueStore());
      final engine = _GatedTtsEngine(deadOnSpeak: true);
      final session = await build(settings, engine);

      await session.start(chapterIndex: 0, paraIndex: 0, fromBookmark: false);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(session.error, isNull);
      expect(session.paused, isTrue);
      expect(session.active, isTrue);
      expect(session.paragraphIndex, 0);

      await session.pause();
      expect(session.paused, isTrue);
      await session.stop();
      expect(session.active, isFalse);
    });

    test('引擎初始化失败（system_unavailable）仍提示，pause 可清除并复位', () async {
      final settings = TtsSettingsStore(MemoryKeyValueStore());
      final engine = _GatedTtsEngine(deadOnStart: true);
      final session = await build(settings, engine);

      await session.start(chapterIndex: 0, paraIndex: 0, fromBookmark: false);

      expect(session.error, contains('不可用'));
      expect(session.paused, isTrue);

      await session.pause();
      expect(session.error, isNull);
      expect(session.paused, isTrue);
      await session.stop();
      expect(session.active, isFalse);
    });
  });
}
