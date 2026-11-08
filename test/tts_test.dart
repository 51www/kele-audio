import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:kele_audio/core/api/key_value_store.dart';
import 'package:kele_audio/core/domain/reader_book.dart';
import 'package:kele_audio/core/services/player/media_bridge.dart';
import 'package:kele_audio/core/services/player/playback_arbiter.dart';
import 'package:kele_audio/core/services/reader/book_store.dart';
import 'package:kele_audio/core/services/reader/reader_activity_store.dart';
import 'package:kele_audio/core/services/tts/tts_engine.dart';
import 'package:kele_audio/core/services/tts/tts_engine_system.dart';
import 'package:kele_audio/core/services/tts/tts_session.dart';
import 'package:kele_audio/core/services/tts/tts_settings_store.dart';

class _FakePort implements TtsReaderPort {
  _FakePort(this.chapters);

  final List<List<String>> chapters;
  final List<int> highlights = [];
  final List<({int index, int? start, int? end})> marks = [];
  int chapter = 0;

  @override
  Future<int> currentChapter() async => chapter;

  @override
  Future<List<String>> paragraphsOf(int chapterIndex) async {
    chapter = chapterIndex;
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
  Future<int> visibleParagraph() async => 0;
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

ReaderBook _book() => ReaderBook(
      id: 'b1',
      title: '测试书',
      source: ReaderBookSource.localEpub,
      fileName: 'book.epub',
      chapterCount: 2,
      addedAt: DateTime(2026, 1, 1),
    );

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

    expect(engine.spoken.first, '桥头下着雨。风很大，他走进巷子。');
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
      TtsEngine engine,
    ) async {
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
        port: _FakePort([
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
