import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:kele_audio/core/api/album_source.dart';
import 'package:kele_audio/core/api/api_config.dart';
import 'package:kele_audio/core/api/bili_client.dart';
import 'package:kele_audio/core/api/key_value_store.dart';
import 'package:kele_audio/core/api/play_url_service.dart';
import 'package:kele_audio/core/data/daos.dart';
import 'package:kele_audio/core/data/local_database.dart';
import 'package:kele_audio/core/domain/album.dart';
import 'package:kele_audio/core/domain/playback.dart';
import 'package:kele_audio/core/services/mini_player_controller.dart';
import 'package:kele_audio/core/services/player/audio_focus.dart';
import 'package:kele_audio/core/services/player/media_bridge.dart';
import 'package:kele_audio/core/services/player/player_engine.dart';
import 'package:kele_audio/core/services/player/player_service.dart';
import 'package:kele_audio/core/services/player/progress_store.dart';

/// M2 播放核心单测：注入假内核（不创建 media_kit）、假取址、假章节源，
/// 覆盖 PRD §5.4 的 P-03 / P-04 / P-05 / P-08 与连播、循环、上一章习惯。

// ───────────────────────────────────────────────────────────── 假内核

class FakeEngine implements PlayerEngine {
  final positionC = StreamController<Duration>.broadcast();
  final durationC = StreamController<Duration>.broadcast();
  final playingC = StreamController<bool>.broadcast();
  final bufferingC = StreamController<bool>.broadcast();
  final completedC = StreamController<void>.broadcast();
  final errorsC = StreamController<String>.broadcast();

  /// open 时命中的 URL 会抛错（模拟 403 播不了）
  String? brokenPattern;

  final List<({String url, Duration startAt, bool autoplay})> opens = [];
  final List<Duration> seeks = [];
  double appliedRate = 1.0;
  bool _disposed = false;

  @override
  Stream<Duration> get position => positionC.stream;

  @override
  Stream<Duration> get duration => durationC.stream;

  @override
  Stream<bool> get playing => playingC.stream;

  @override
  Stream<bool> get buffering => bufferingC.stream;

  @override
  Stream<void> get completed => completedC.stream;

  @override
  Stream<String> get errors => errorsC.stream;

  @override
  Duration get positionValue => Duration.zero;

  @override
  Duration get durationValue => Duration.zero;

  @override
  bool get isPlaying => false;

  @override
  double get rate => appliedRate;

  /// 当前生效音量（duck 逻辑用它断言）
  double appliedVolume = 1.0;

  @override
  double get volume => appliedVolume;

  @override
  Future<void> open({
    required String url,
    Map<String, String>? headers,
    bool autoplay = true,
    Duration startAt = Duration.zero,
  }) async {
    final pattern = brokenPattern;
    if (pattern != null && url.contains(pattern)) {
      // 真实 media_kit：坏地址多数不抛错，而是走 errors 流；
      // 两种路径都模拟，PlayerService 都应自愈。
      errorsC.add('HTTP 403 (CDN refused)');
      throw StateError('打开失败：$url');
    }
    opens.add((url: url, startAt: startAt, autoplay: autoplay));
  }

  @override
  Future<void> play() async => playingC.add(true);

  @override
  Future<void> pause() async => playingC.add(false);

  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(Duration to) async => seeks.add(to);

  @override
  Future<void> setRate(double v) async => appliedRate = v;

  @override
  Future<void> setVolume(double v) async => appliedVolume = v;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await positionC.close();
    await durationC.close();
    await playingC.close();
    await bufferingC.close();
    await completedC.close();
    await errorsC.close();
  }
}

// ─────────────────────────────────────────────────────── 假取址 / 章节源

class FakePlayUrl extends PlayUrlService {
  FakePlayUrl()
        : super(
          client: BiliClient(
            config: ApiConfig.defaults(),
            kv: MemoryKeyValueStore(),
          ),
          config: ApiConfig.defaults(),
        );

  final List<({String bvid, int cid, bool forceRefresh})> calls = [];

  /// 当前可返回的候选地址
  List<String> urls = ['https://cdn.example/ok-a.m4s'];

  @override
  Future<List<String>> resolve({
    required String bvid,
    required int cid,
    AudioQuality quality = AudioQuality.q132k,
    bool forceRefresh = false,
  }) async {
    calls.add((bvid: bvid, cid: cid, forceRefresh: forceRefresh));
    return urls;
  }

  @override
  Map<String, String> headersFor(String bvid) => {'User-Agent': 'fake'};

  @override
  void invalidate(String bvid, int cid) {
    calls.add((bvid: bvid, cid: cid, forceRefresh: true)); // 标记作废
  }
}

class FakeAlbumSource extends AlbumSource {
  FakeAlbumSource()
        : super(
          client: BiliClient(
            config: ApiConfig.defaults(),
            kv: MemoryKeyValueStore(),
          ),
          config: ApiConfig.defaults(),
        );
}

// ─────────────────────────────────────────────────────── 假音频焦点

/// 可手动触发系统音频焦点事件（打断/丢失/压低/恢复/拔耳机）。
class FakeFocus implements AudioFocus {
  @override
  void Function()? onFocusLost;
  @override
  void Function()? onFocusInterrupted;
  @override
  void Function()? onFocusDucked;
  @override
  void Function()? onFocusGained;
  @override
  void Function()? onNoisy;

  bool started = false;
  int requestCount = 0;
  int abandonCount = 0;

  @override
  Future<void> start() async => started = true;

  @override
  Future<bool> request() async {
    requestCount++;
    return true;
  }

  @override
  Future<void> abandon() async => abandonCount++;

  @override
  void dispose() {}

  // 事件模拟
  void fireLost() => onFocusLost?.call();
  void fireInterrupted() => onFocusInterrupted?.call();
  void fireDucked() => onFocusDucked?.call();
  void fireGained() => onFocusGained?.call();
  void fireNoisy() => onNoisy?.call();
}

// ─────────────────────────────────────────────────────────── 测试环境

/// 一套完整的假环境；[restart] 用同一个 kv 模拟「杀进程重开」。
class Harness {
  Harness(this.kv, {AudioFocus? focus}) : _focus = focus ?? AudioFocus();

  final KeyValueStore kv;
  final AudioFocus _focus;

  late final LocalDatabase db = LocalDatabase(kv);
  late final Daos daos = Daos(db);
  final FakePlayUrl playUrl = FakePlayUrl();
  final FakeAlbumSource albums = FakeAlbumSource();
  final MiniPlayerController mini = MiniPlayerController();
  FakeEngine? _engine;
  PlayerService? _player;

  FakeEngine get engine => _engine!;
  PlayerService get player => _player!;

  Future<PlayerService> start() async {
    await db.ensureCreated();
    _engine = FakeEngine();
    final p = PlayerService(
      playUrl: playUrl,
      albumSource: albums,
      daos: daos,
      store: ProgressStore(daos),
      prefs: PlayerPrefs(kv),
      miniPlayer: mini,
      saveInterval: const Duration(seconds: 15),
      focus: _focus,
      media: NoopMediaBridge(),
      engineFactory: () => _engine!,
    );
    await p.init();
    _player = p;
    return p;
  }

  /// 同一份本地数据 + 全新引擎/服务 = 冷启动（旧实例先销毁）
  Future<PlayerService> restart() async {
    _player?.dispose();
    _player = null;
    return start();
  }

  Future<void> dispose() async {
    _player?.dispose();
    _player = null;
  }
}

Album makeAlbum() => Album(
      id: 'BV1TEST',
      sourceType: SourceType.multiPart,
      title: '测试专辑',
      coverUrl: '',
      upName: '测试UP',
      chapterCount: 3,
      categoryId: 'rec',
      bvid: 'BV1TEST',
      createdAt: 1,
    );

List<Chapter> makeChapters() => [
      for (var i = 1; i <= 3; i++)
        Chapter(
          id: Chapter.keyOf('BV1TEST', 100 + i),
          albumId: 'BV1TEST',
          index: i - 1,
          title: '第$i章',
          durationSec: 100,
          bvid: 'BV1TEST',
          cid: 100 + i,
        ),
    ];

Harness makeHarness() => Harness(MemoryKeyValueStore());

/// 注入假音频焦点的环境（P-07 焦点/拔耳机用例）
Harness makeFocusHarness(FakeFocus focus) =>
    Harness(MemoryKeyValueStore(), focus: focus);

/// 等待事件流与异步编排跑完（假内核的流是异步广播）
Future<void> settle([int rounds = 3]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('P-03 断点续播：flush 后冷启动恢复「专辑 + 章节 + 秒级进度」', () async {
    final h = makeHarness();
    final p = await h.start();
    final chapters = makeChapters();

    expect(await p.playAlbum(makeAlbum(), chapters: chapters), isTrue);
    // 引擎上报进度到 42s
    h.engine.durationC.add(const Duration(seconds: 100));
    h.engine.positionC.add(const Duration(seconds: 42));
    await settle();
    await p.flushProgress();

    // 落库检查：play_history 秒级进度
    final saved = h.daos.playHistory.recent(limit: 1).first;
    expect(saved.positionSec, 42);
    expect(saved.chapterId, chapters.first.id);

    // 杀进程重开：恢复会话但**不自动发声**
    final p2 = await h.restart();
    expect(await p2.restoreLastSession(), isTrue);
    expect(p2.hasSession, isTrue);
    expect(p2.index, 0);
    expect(p2.position, const Duration(seconds: 42));
    expect(p2.playing, isFalse);
    expect(p2.mediaReady, isFalse);

    // MiniPlayer 收到了恢复后的会话
    expect(h.mini.state.hasTask, isTrue);
    expect(h.mini.state.albumTitle, '测试专辑');

    await h.dispose();
  });

  test('播放条关闭后，新播放任务自动重新显示（需求2）', () async {
    final h = makeHarness();
    final p = await h.start();
    final chapters = makeChapters();

    expect(await p.playAlbum(makeAlbum(), chapters: chapters), isTrue);
    await settle();
    expect(h.mini.visible, isTrue); // 有播放任务 → 显示

    // 点 ✕ 关闭播放条（模拟：正在播先暂停 + 收起）
    await p.pause();
    h.mini.close();
    expect(h.mini.visible, isFalse);

    // 点某一集 / 切章 = 新播放任务 → 播放条回来
    await p.playChapterAt(1);
    await settle();
    expect(h.mini.visible, isTrue);
    expect(h.mini.state.chapterTitle, '第2章');

    await h.dispose();
  });

  test('P-04 跨章续播：重进专辑定位到最后听的章节与进度', () async {
    final h = makeHarness();
    final p = await h.start();
    final chapters = makeChapters();

    await p.playAlbum(makeAlbum(), chapters: chapters);
    await p.playChapterAt(1); // 切到第 2 章
    h.engine.durationC.add(const Duration(seconds: 100));
    h.engine.positionC.add(const Duration(seconds: 30));
    await settle();
    await p.flushProgress();
    await h.dispose();

    final p2 = await h.restart();
    await p2.playAlbum(makeAlbum()); // 不指定章节 → 应定位到第 2 章
    await settle();
    expect(p2.index, 1);
    expect(p2.currentChapter?.title, '第2章');
    // 续播位置：换源瞬间以 startAt 为准
    expect(h.engine.opens.last.startAt, const Duration(seconds: 30));

    await h.dispose();
  });

  test('P-08 倍速/音质/播放模式持久化：重启后保留', () async {
    final h = makeHarness();
    final p = await h.start();
    final chapters = makeChapters();

    // 先播起来（引擎懒加载：播放时才创建）
    await p.playAlbum(makeAlbum(), chapters: chapters);
    await p.setRate(1.5);
    await p.setQuality(AudioQuality.q192k);
    await p.setMode(PlayMode.loopAll);
    expect(h.engine.rate, 1.5); // 引擎同步生效
    await h.dispose();

    final p2 = await h.restart();
    expect(p2.rate, 1.5);
    expect(p2.quality, AudioQuality.q192k);
    expect(p2.mode, PlayMode.loopAll);
    expect(p2.rateLabel, '1.5x');
    await h.dispose();
  });

  test('P-05 地址失效自愈：报错后重取地址并回到原进度续播', () async {
    final h = makeHarness();
    final p = await h.start();
    final chapters = makeChapters();

    await p.playAlbum(makeAlbum(), chapters: chapters);
    h.engine.durationC.add(const Duration(seconds: 100));
    h.engine.positionC.add(const Duration(seconds: 42));
    await settle();

    // 模拟地址过期：内存地址作废 + 当前音源立即失效（403）
    h.playUrl.urls = ['https://cdn.example/ok-b.m4s'];
    h.engine.brokenPattern = 'expired';
    await p.debugExpireCurrentUrl();
    await settle(5);

    // 自愈链路：重取地址（forceRefresh）→ 打开新地址 → 回到 42s
    final resolveCalls = h.playUrl.calls.where((c) => c.forceRefresh).toList();
    expect(resolveCalls, isNotEmpty);
    final lastOpen = h.engine.opens.last;
    expect(lastOpen.url, 'https://cdn.example/ok-b.m4s');
    expect(lastOpen.startAt, const Duration(seconds: 42));
    expect(p.error, isNull);
    expect(p.recovering, isFalse);

    await h.dispose();
  });

  test('分 P 连播：一章播完自动开下一章', () async {
    final h = makeHarness();
    final p = await h.start();
    final chapters = makeChapters();

    await p.playAlbum(makeAlbum(), chapters: chapters);
    h.engine.durationC.add(const Duration(seconds: 100));
    h.engine.positionC.add(const Duration(seconds: 98));
    await settle();

    h.engine.completedC.add(null); // 自然播完
    await settle(5);

    expect(p.index, 1);
    expect(p.currentChapter?.title, '第2章');
    expect(h.engine.opens.length, 2);

    await h.dispose();
  });

  test('列表循环：最后一章回到第一章；顺序播放则停下', () async {
    final h = makeHarness();
    final p = await h.start();
    final chapters = makeChapters();

    await p.playAlbum(makeAlbum(), chapters: chapters, startIndex: 2);
    await p.setMode(PlayMode.loopAll);
    h.engine.durationC.add(const Duration(seconds: 100));
    h.engine.positionC.add(const Duration(seconds: 98));
    await settle();

    h.engine.completedC.add(null);
    await settle(5);
    expect(p.index, 0); // 回到第一章
    await h.dispose();

    // 顺序播放：最后一章播完 → 暂停，不再开新章
    final h2 = makeHarness();
    final p2 = await h2.start();
    await p2.playAlbum(makeAlbum(), chapters: chapters, startIndex: 2);
    h2.engine.durationC.add(const Duration(seconds: 100));
    h2.engine.positionC.add(const Duration(seconds: 98));
    await settle();
    final opensBefore = h2.engine.opens.length;
    h2.engine.completedC.add(null);
    await settle(5);
    expect(h2.engine.opens.length, opensBefore); // 没有开新章
    expect(p2.playing, isFalse);
    await h2.dispose();
  });

  test('上一章习惯：播放超 5s 重播本章，否则回上一章', () async {
    final h = makeHarness();
    final p = await h.start();
    final chapters = makeChapters();

    await p.playAlbum(makeAlbum(), chapters: chapters);
    h.engine.durationC.add(const Duration(seconds: 100));
    h.engine.positionC.add(const Duration(seconds: 42)); // > 5s
    await settle();

    await p.previous();
    expect(h.engine.seeks, contains(Duration.zero));
    expect(p.index, 0); // 仍本章

    await p.playChapterAt(2);
    h.engine.positionC.add(const Duration(seconds: 3)); // < 5s
    await settle();
    await p.previous();
    await settle();
    expect(p.index, 1); // 回上一章

    await h.dispose();
  });

  test('音质切换：持久化 + 重新取址 + 回原进度续播', () async {
    final h = makeHarness();
    final p = await h.start();
    final chapters = makeChapters();

    await p.playAlbum(makeAlbum(), chapters: chapters);
    h.engine.durationC.add(const Duration(seconds: 100));
    h.engine.positionC.add(const Duration(seconds: 21));
    await settle();

    await p.setQuality(AudioQuality.q64k);
    await settle(5);

    expect(p.quality, AudioQuality.q64k);
    final forced = h.playUrl.calls.where((c) => c.forceRefresh).toList();
    expect(forced, isNotEmpty);
    expect(h.engine.opens.last.startAt, const Duration(seconds: 21));

    await h.dispose();
  });

  test('睡眠定时：本章结束开关持久化，取消后复位', () async {
    final h = makeHarness();
    final p = await h.start();

    await p.setSleepTimer(minutes: 0); // 本章结束
    expect(p.stopAtChapterEnd, isTrue);

    await p.setSleepTimer(minutes: 15);
    expect(p.hasSleepTimer, isTrue);
    expect(p.stopAtChapterEnd, isFalse);

    await p.cancelSleepTimer();
    expect(p.hasSleepTimer, isFalse);

    await h.dispose();

    final p2 = await h.restart();
    expect(p2.stopAtChapterEnd, isFalse); // 关闭状态也持久化
    await h.dispose();
  });

  test('书架联动：播放进度同步到已收藏专辑的收听字段', () async {
    final h = makeHarness();
    final p = await h.start();
    final chapters = makeChapters();

    await h.daos.shelf.add('BV1TEST'); // 先收藏
    await p.playAlbum(makeAlbum(), chapters: chapters);
    h.engine.durationC.add(const Duration(seconds: 100));
    h.engine.positionC.add(const Duration(seconds: 42));
    await settle();
    await p.flushProgress();

    final item = h.daos.shelf.list().first;
    expect(item.lastChapterId, chapters.first.id);
    expect(item.lastPositionSec, 42);
    expect(item.totalChapters, 3);

    await h.dispose();
  });

  // ───────────────────────────────────────── P-07 音频焦点 / 拔耳机

  test('P-07 短暂打断（interrupted→gained）：暂停后自动续播', () async {
    final focus = FakeFocus();
    final h = makeFocusHarness(focus);
    final p = await h.start();
    final chapters = makeChapters();

    await p.playAlbum(makeAlbum(), chapters: chapters);
    h.engine.positionC.add(const Duration(seconds: 42));
    await settle();
    expect(p.playing, isTrue);

    focus.fireInterrupted(); // 来电/导航播报抢占
    await settle();
    expect(p.playing, isFalse, reason: '打断须暂停');

    focus.fireGained(); // 打断结束
    await settle(5);
    expect(p.playing, isTrue, reason: '短暂打断须自动续播');

    await h.dispose();
  });

  test('P-07 完全丢失（lost→gained）：暂停但不自动续播', () async {
    final focus = FakeFocus();
    final h = makeFocusHarness(focus);
    final p = await h.start();
    final chapters = makeChapters();

    await p.playAlbum(makeAlbum(), chapters: chapters);
    await settle();
    expect(p.playing, isTrue);

    focus.fireLost(); // 其他 App 长期占用焦点
    await settle();
    expect(p.playing, isFalse, reason: '完全丢失须暂停');

    focus.fireGained();
    await settle(5);
    expect(p.playing, isFalse, reason: '用户未操作不得自动恢复');

    await h.dispose();
  });

  test('P-07 焦点被压低（ducked）：音量降到 0.3，恢复后还原 1.0', () async {
    final focus = FakeFocus();
    final h = makeFocusHarness(focus);
    final p = await h.start();
    final chapters = makeChapters();

    await p.playAlbum(makeAlbum(), chapters: chapters);
    await settle();
    expect(h.engine.appliedVolume, 1.0);

    focus.fireDucked(); // 导航提示音等短促抢占
    await settle();
    expect(h.engine.appliedVolume, 0.3, reason: 'duck 须降到 0.3');
    expect(p.playing, isTrue, reason: 'duck 不应打断播放');

    focus.fireGained();
    await settle();
    expect(h.engine.appliedVolume, 1.0, reason: '恢复须还原音量');

    await h.dispose();
  });

  test('P-07 拔耳机（becoming noisy）：暂停且不自动续播', () async {
    final focus = FakeFocus();
    final h = makeFocusHarness(focus);
    final p = await h.start();
    final chapters = makeChapters();

    await p.playAlbum(makeAlbum(), chapters: chapters);
    await settle();
    expect(p.playing, isTrue);

    focus.fireNoisy(); // AUDIO_BECOMING_NOISY
    await settle();
    expect(p.playing, isFalse, reason: '拔耳机须暂停');

    focus.fireGained();
    await settle(5);
    expect(p.playing, isFalse, reason: '拔耳机后不得自动恢复');

    await h.dispose();
  });

  // ────────────────────────────────────────────── M5 设置页接线

  test('M5 自动连播开关：关闭后本章播完即停（单曲循环不受影响）', () async {
    final h = makeHarness();
    final p = await h.start();
    final chapters = makeChapters();

    await p.setAutoNext(false);
    expect(p.autoNext, isFalse);

    // 中间章播完 → 不开下一章
    await p.playAlbum(makeAlbum(), chapters: chapters);
    h.engine.durationC.add(const Duration(seconds: 100));
    h.engine.positionC.add(const Duration(seconds: 98));
    await settle();
    h.engine.completedC.add(null);
    await settle(5);
    expect(h.engine.opens.length, 1, reason: '自动连播关闭不得开新章');
    expect(p.playing, isFalse, reason: '本章播完须暂停');

    // 持久化：重启后仍为关
    final p2 = await h.restart();
    expect(p2.autoNext, isFalse);

    // 单曲循环是重播本章、非「下一章」，不受开关影响（seek 归零续播，不开新章）
    await p2.setMode(PlayMode.loopOne);
    await p2.playAlbum(makeAlbum(), chapters: chapters, startIndex: 0);
    h.engine.durationC.add(const Duration(seconds: 100));
    h.engine.positionC.add(const Duration(seconds: 98));
    await settle();
    final opensBefore = h.engine.opens.length;
    final seeksBefore = h.engine.seeks.length;
    h.engine.completedC.add(null);
    await settle(5);
    expect(h.engine.opens.length, opensBefore, reason: '单曲循环不换章');
    expect(h.engine.seeks.length, greaterThan(seeksBefore),
        reason: '单曲循环须回退重播');
    expect(p2.index, 0, reason: '单曲循环不得切章');
    expect(p2.playing, isTrue, reason: '单曲循环须继续播');

    await h.dispose();
  });

  test('M5 默认音质：setDefaultQuality 只改之后取址，不打断正在播', () async {
    final h = makeHarness();
    final p = await h.start();
    final chapters = makeChapters();

    await p.playAlbum(makeAlbum(), chapters: chapters);
    h.engine.durationC.add(const Duration(seconds: 100));
    h.engine.positionC.add(const Duration(seconds: 21));
    await settle();

    final opensBefore = h.engine.opens.length;
    final forcedBefore =
        h.playUrl.calls.where((c) => c.forceRefresh).length;

    await p.setDefaultQuality(AudioQuality.q64k);
    await settle();
    expect(p.quality, AudioQuality.q64k);
    expect(h.engine.opens.length, opensBefore, reason: '不得重开流');
    expect(h.playUrl.calls.where((c) => c.forceRefresh).length, forcedBefore,
        reason: '不得强制重取址');
    expect(p.playing, isTrue, reason: '正在播不得被打断');

    // 持久化：重启后保留
    final p2 = await h.restart();
    expect(p2.quality, AudioQuality.q64k);
    await h.dispose();
  });
}
