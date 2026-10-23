import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;

import '../../api/album_source.dart';
import '../../api/play_url_service.dart';
import '../../data/daos.dart';
import '../../domain/album.dart';
import '../../domain/playback.dart';
import '../mini_player_controller.dart';
import 'audio_focus.dart';
import 'media_bridge.dart';
import 'media_kit_engine.dart';
import 'player_engine.dart';
import 'progress_store.dart';

/// 播放核心（**M2 关键路径**）：专辑 → 章节 → 取址 → 播放 → 进度持久化。
///
/// 覆盖 PRD §5.4.2 的八条硬性要求：
///
/// | 条目 | 实现位置 |
/// |---|---|
/// | P-01 后台播放 | 音频焦点 + `MediaSessionBridge`（`audio_service`）|
/// | P-02 锁屏/通知栏控制 | [_bindMedia] → [MediaSessionBridge.publish] |
/// | P-03 断点续播 | [_saveNow] 节流 15s + 暂停/切章/退后台 flush |
/// | P-04 跨章续播 | [restoreLastSession] / [playAlbum] 读 `play_history` |
/// | P-05 地址失效自愈 | [_onEngineError] → [_recover]（重取地址 + seek 回原位）|
/// | P-06 线控/蓝牙 | [MediaSessionBridge.bind] 的 prev/next/play/pause |
/// | P-07 音频焦点 | [AudioFocus]（原生 MethodChannel）|
/// | P-08 倍速/定时持久化 | [PlayerPrefs]（倍速、音质、播放模式）|
///
/// 两处刻意的设计：
/// 1. **不 import `audio_service`**：系统集成全部走 [MediaSessionBridge]，
///    播放核心保持纯 Dart，单测可注入假内核（[engineFactory]）；
/// 2. **高频进度不走 `notifyListeners`**：位置更新只推 [positionTick]，
///    避免 4Hz 全页重建；状态变化（播放态/切章/加载）才整页刷新。
class PlayerService extends ChangeNotifier
    with WidgetsBindingObserver, DiagnosticableTreeMixin {
  PlayerService({
    required this.playUrl,
    required this.albumSource,
    required this.daos,
    required this.store,
    required this.prefs,
    required this.miniPlayer,
    required this.saveInterval,
    AudioFocus? focus,
    MediaSessionBridge? media,
    PlayerEngine Function()? engineFactory,
    this.log,
  })  : _focus = focus ?? AudioFocus.instance,
        _media = media ?? NoopMediaBridge(),
        _engineFactory = engineFactory ?? createPlayerEngine {
    _rate = prefs.rate;
    _mode = prefs.mode;
    _quality = prefs.quality;
    _stopAtChapterEnd = prefs.stopAtChapterEnd;
  }

  final PlayUrlService playUrl;
  final AlbumSource albumSource;
  final Daos daos;
  final ProgressStore store;
  final PlayerPrefs prefs;
  final MiniPlayerController miniPlayer;

  /// 播放中的落盘节流（PRD：15~30s）
  final Duration saveInterval;

  final AudioFocus _focus;
  final MediaSessionBridge _media;
  final PlayerEngine Function() _engineFactory;
  final void Function(String message)? log;

  /// 常用倍速档（PRD §5.4：0.75/1.0/1.25/1.5/2.0 为常用档）
  static const List<double> speedSteps = <double>[
    0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0,
  ];

  // ------------------------------------------------------------------ 引擎
  PlayerEngine? _engine;
  bool _engineBound = false;
  final List<StreamSubscription<dynamic>> _subs = [];

  /// 懒加载引擎：**单测里从不真正创建 media_kit**（注入假内核即可）。
  PlayerEngine get engine {
    final e = _engine ??= _engineFactory();
    if (!_engineBound) {
      _bindEngine(e);
      _engineBound = true;
    }
    return e;
  }

  // ------------------------------------------------------------------ 状态
  Album? _album;
  List<Chapter> _chapters = const [];
  int _index = -1;

  bool _loading = false;
  bool _playing = false;
  bool _buffering = false;
  bool _recovering = false;
  bool _mediaReady = false;
  bool _started = false;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  /// 最近一次**可信**的播放位置：换源瞬间的 0 不会污染它，
  /// P-05 自愈靠它把进度接回去。
  Duration _lastKnown = Duration.zero;

  String? _error;
  int _session = 0;
  int _recoverTries = 0;
  Duration? _recoverFloor;

  double _rate = 1.0;
  PlayMode _mode = PlayMode.sequential;
  AudioQuality _quality = AudioQuality.q132k;
  bool _stopAtChapterEnd = false;

  Duration _sleepRemaining = Duration.zero;
  Timer? _sleepTimer;

  DateTime _lastSaveAt = DateTime.fromMillisecondsSinceEpoch(0);
  Duration _tallyPos = Duration.zero;
  Duration _tally = Duration.zero;

  Duration _watchPos = Duration.zero;
  DateTime _watchAt = DateTime.now();

  DateTime _lastMiniPush = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastBridgePush = DateTime.fromMillisecondsSinceEpoch(0);

  Timer? _watchdog;
  bool _disposed = false;

  /// 播放位置（高频，独立于 [notifyListeners]，供进度条/时间文本插值）
  final ValueNotifier<Duration> positionTick = ValueNotifier(Duration.zero);

  // ---------------------------------------------------------------- 只读视图
  Album? get album => _album;
  List<Chapter> get chapters => List.unmodifiable(_chapters);
  int get index => _index;
  Chapter? get currentChapter =>
      _index >= 0 && _index < _chapters.length ? _chapters[_index] : null;
  bool get hasSession => _album != null && _index >= 0;
  bool get hasNext => _index >= 0 && _index < _chapters.length - 1;
  bool get hasPrev => _index > 0;

  bool get loading => _loading;
  bool get playing => _playing;
  bool get buffering => _buffering;
  bool get recovering => _recovering;
  bool get mediaReady => _mediaReady;
  bool get started => _started;
  String? get error => _error;

  Duration get position => _position;
  Duration get duration => _duration;
  double get rate => _rate;
  PlayMode get mode => _mode;
  AudioQuality get quality => _quality;
  bool get stopAtChapterEnd => _stopAtChapterEnd;
  Duration get sleepRemaining => _sleepRemaining;
  bool get hasSleepTimer => _sleepTimer != null;

  /// 0~1（时长未知时为 0）
  double get progress {
    final total = _duration.inMilliseconds;
    if (total <= 0) return 0;
    return (_position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  String get rateLabel {
    final r = _rate;
    return r == r.roundToDouble()
        ? '${r.toInt()}x'
        : '${r.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')}x';
  }

  // ================================================================ 生命周期

  /// 启动装配（**零网络、零引擎**）：读持久化参数 + 挂生命周期/焦点/系统桥。
  Future<void> init() async {
    if (_started) return;
    _started = true;
    _bindMedia();
    _focus.start();
    WidgetsBinding.instance.addObserver(this);
    // 看门狗随播放懒启动（_ensureWatchdog），空闲不空转
    notifyListeners();
  }

  /// 冷启动恢复（**P-03 / P-04**）：把上次的专辑/章节/进度装载到内存，
  /// **不自动发声**，用户按播放才从该位置续播。
  Future<bool> restoreLastSession({bool autoPlay = false}) async {
    final last = store.lastOverall();
    if (last == null) return false;
    final album = daos.albums.get(last.albumId);
    final chapters = daos.chapters.byAlbum(last.albumId);
    if (album == null || chapters.isEmpty) return false;

    if (_mediaReady && _album?.id == album.id && _index >= 0) return true;

    var idx = chapters.indexWhere((c) => c.id == last.chapterId);
    if (idx < 0) idx = 0;

    _album = album;
    _chapters = chapters;
    _index = idx;
    _position = Duration(seconds: last.positionSec);
    _lastKnown = _position;
    _duration = Duration(seconds: last.durationSec);
    _mediaReady = false;
    positionTick.value = _position;
    _error = null;
    notifyListeners();
    _log('[restore] ${album.title} → 第 ${idx + 1} 章 @${_position.inSeconds}s');

    if (autoPlay) {
      return _openChapter(idx, startAt: _position, autoPlay: true);
    }
    return true;
  }

  // ================================================================ 播放入口

  /// 开始播放一张专辑（详情页「播放全部」/ 卡片点击）。
  ///
  /// 不指定章节时按 **P-04** 定位到「最后听的章节 + 秒级进度」。
  Future<bool> playAlbum(
    Album album, {
    List<Chapter>? chapters,
    int? startIndex,
    Duration startAt = Duration.zero,
    bool autoPlay = true,
  }) async {
    var list = chapters;
    if (list == null || list.isEmpty) {
      if (daos.albums.get(album.id) != null) {
        final cached = daos.chapters.byAlbum(album.id);
        if (cached.isNotEmpty) list = cached;
      }
      list ??= await _loadChapters(album);
    }
    if (list.isEmpty) {
      _error = '这张专辑没有可播放的章节';
      notifyListeners();
      return false;
    }

    int index;
    Duration pos;
    if (startIndex != null) {
      index = startIndex.clamp(0, list.length - 1);
      pos = startAt;
    } else {
      final last = store.lastOfAlbum(album.id);
      final hit = last == null
          ? -1
          : list.indexWhere((c) => c.id == last.chapterId);
      index = hit < 0 ? 0 : hit;
      pos = (hit < 0 || last == null)
          ? Duration.zero
          : Duration(seconds: last.positionSec);
      if (index == 0 && pos == Duration.zero) pos = startAt;
    }

    return _openChapter(
      index,
      startAt: pos,
      autoPlay: autoPlay,
      album: album,
      chapters: list,
    );
  }

  Future<List<Chapter>> _loadChapters(Album album) async {
    final bundle = await albumSource.load(
      id: album.id,
      sourceType: album.sourceType,
      categoryId: album.categoryId,
    );
    if (bundle.chapters.isNotEmpty) {
      await daos.albums.upsert(bundle.album);
      await daos.chapters.upsertAll(bundle.chapters);
      if (bundle.album.id == album.id) return bundle.chapters;
    }
    return daos.chapters.byAlbum(album.id);
  }

  /// 播放下标为 [index] 的章节（**唯一**的装载路径，失败会回滚状态）。
  Future<bool> _openChapter(
    int index, {
    required Duration startAt,
    bool autoPlay = true,
    Album? album,
    List<Chapter>? chapters,
  }) async {
    final targetAlbum = album ?? _album;
    final targetChapters = chapters ?? _chapters;
    if (targetAlbum == null ||
        targetChapters.isEmpty ||
        index < 0 ||
        index >= targetChapters.length) {
      _error = '没有可播放的章节';
      notifyListeners();
      return false;
    }

    final mySession = ++_session;
    _loading = true;
    _error = null;
    notifyListeners();

    final chapter = targetChapters[index];
    var opened = false;
    try {
      var cid = chapter.cid;
      if (cid == 0) {
        // 合集/系列章节：列表里没有 cid，播放前用 view/pagelist 补齐
        cid = await albumSource.resolveCid(chapter);
        if (cid == 0) throw StateError('章节地址解析失败（cid 为空）');
      }
      final bvid = chapter.bvid.isEmpty ? targetAlbum.bvid : chapter.bvid;
      if (bvid.isEmpty) throw StateError('章节缺少 bvid，无法取址');

      final candidates = await playUrl.resolve(
        bvid: bvid,
        cid: cid,
        quality: _quality,
      );
      if (mySession != _session) return false;

      for (var i = 0; i < candidates.length; i++) {
        try {
          await engine.open(
            url: candidates[i],
            headers: playUrl.headersFor(bvid),
            autoplay: autoPlay,
            startAt: startAt,
          );
          opened = true;
          break;
        } catch (e) {
          _log('[open] 候选 $i 打开失败：$e');
          if (i < candidates.length - 1) await engine.stop();
        }
      }
      if (!opened) throw StateError('所有候选地址都无法播放');

      // 成功才提交状态（失败则保持原专辑/章节/下标不动）
      if (mySession != _session) return false;
      _album = targetAlbum;
      _chapters = targetChapters;
      _index = index;
      _mediaReady = true;
      _playing = autoPlay;
      _position = startAt;
      _lastKnown = startAt;
      _tallyPos = startAt;
      _duration = Duration.zero;
      positionTick.value = startAt;
      _recoverTries = 0;
      _recoverFloor = null;
      _lastSaveAt = DateTime.now();
      _watchPos = startAt;
      _watchAt = DateTime.now();

      // 落库：专辑 + 章节，是 P-04 冷启动恢复的数据基础（**地址永不落库**）
      await daos.albums.upsert(targetAlbum);
      await daos.chapters.upsertAll(targetChapters);
      if (cid != chapter.cid) {
        _chapters = [
          for (final c in _chapters)
            if (c.id == chapter.id) c.copyWith(cid: cid) else c,
        ];
        await daos.chapters.upsertAll([_chapters[index]]);
      }
      await _saveNow();
      unawaited(_focus.request());
      _pushBridge(force: true);
      return true;
    } catch (e) {
      if (mySession == _session) {
        _error = '播放失败：$e';
        _mediaReady = false;
        _log('[open] 失败：$e');
      }
      return false;
    } finally {
      if (mySession == _session) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  // ================================================================ 播放控制

  /// 播放 / 暂停切换
  void toggle() => _playing ? unawaited(pause()) : unawaited(play());

  Future<void> play() async {
    if (!hasSession) {
      final ok = await restoreLastSession(autoPlay: true);
      if (!ok) {
        _error = _error ?? '还没有收听记录，去发现页挑一张专辑吧';
        notifyListeners();
      }
      return;
    }
    if (!_mediaReady || _engine == null) {
      await _openChapter(_index, startAt: _lastKnown, autoPlay: true);
      return;
    }
    unawaited(_focus.request());
    await engine.play();
  }

  Future<void> pause() async {
    if (_engine == null) return;
    await engine.pause();
    await _saveNow(); // 暂停立即写盘（PRD §5.4.2）
    await _commitTally();
  }

  /// 停止（通知栏/线控的 stop）：收通知、释放焦点、保留会话与进度
  Future<void> stop() async {
    _session++;
    _loading = false;
    _recovering = false;
    if (_engine != null) {
      await _saveNow();
      await engine.stop();
    }
    _mediaReady = false;
    _playing = false;
    _pushBridge(force: true);
    notifyListeners();
    unawaited(_focus.abandon());
  }

  Future<void> seek(Duration to) async {
    final total = _duration;
    var target = to;
    if (total > Duration.zero && target > total) target = total;
    if (target < Duration.zero) target = Duration.zero;

    _position = target;
    _lastKnown = target;
    _tallyPos = target;
    positionTick.value = target;
    if (_mediaReady && _engine != null) {
      try {
        await engine.seek(target);
      } catch (e) {
        _log('[seek] 失败：$e');
      }
    }
    unawaited(_saveNow()); // 拖动进度立即写盘
    _pushBridge(force: true);
    notifyListeners();
  }

  Future<void> seekRelative(int seconds) =>
      seek(_position + Duration(seconds: seconds));

  /// 听书习惯：播放超过 5s 再点「上一章」＝重播本章，否则回上一章
  Future<void> previous() async {
    if (_position > const Duration(seconds: 5)) {
      await seek(Duration.zero);
      await play();
      return;
    }
    if (_index > 0) {
      await playChapterAt(_index - 1);
    } else {
      await seek(Duration.zero);
    }
  }

  Future<void> next() async {
    if (hasNext) {
      await playChapterAt(_index + 1);
    } else if (_mode == PlayMode.loopAll && _chapters.isNotEmpty) {
      await playChapterAt(0);
    }
  }

  /// 跳到指定章节（章节抽屉 / 详情页点击）
  Future<void> playChapterAt(int index, {Duration startAt = Duration.zero}) async {
    if (index < 0 || index >= _chapters.length) return;
    final keepPlaying = _playing || !_mediaReady;
    if (_mediaReady) unawaited(_saveNow());
    await _openChapter(index, startAt: startAt, autoPlay: keepPlaying);
  }

  // ================================================================ 倍速/模式

  Future<void> setRate(double v) async {
    _rate = v.clamp(0.5, 3.0);
    await prefs.saveRate(_rate);
    if (_engine != null) await engine.setRate(_rate);
    _pushBridge(force: true);
    notifyListeners();
  }

  /// 在常用档位间循环（播放页一键）
  Future<void> cycleRate() {
    var idx = speedSteps.indexWhere((e) => (e - _rate).abs() < 0.001);
    if (idx < 0) {
      idx = speedSteps.indexWhere((e) => e > _rate);
      if (idx < 0) idx = 0;
    } else {
      idx = (idx + 1) % speedSteps.length;
    }
    return setRate(speedSteps[idx]);
  }

  Future<void> setMode(PlayMode mode) async {
    _mode = mode;
    await prefs.saveMode(mode);
    notifyListeners();
  }

  /// 音质切换（64K / 132K / 192K）：立即用新档位重新取址并续播。
  Future<void> setQuality(AudioQuality q) async {
    if (q == _quality) return;
    _quality = q;
    await prefs.saveQuality(q);
    notifyListeners();
    if (_mediaReady && hasSession) {
      await _recover(forceRefresh: true, reason: '切换音质 $q');
    }
  }

  Future<void> setStopAtChapterEnd(bool v) async {
    _stopAtChapterEnd = v;
    await prefs.saveStopAtChapterEnd(v);
    notifyListeners();
  }

  // ================================================================ 睡眠定时

  /// 定时关闭：[minutes] 为 null 表示关闭；0 表示「本章结束」。
  Future<void> setSleepTimer({int? minutes}) async {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepRemaining = Duration.zero;
    if (minutes == null) {
      await setStopAtChapterEnd(false);
      notifyListeners();
      return;
    }
    if (minutes == 0) {
      await setStopAtChapterEnd(true);
      notifyListeners();
      return;
    }
    await setStopAtChapterEnd(false);
    _sleepRemaining = Duration(minutes: minutes);
    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      _sleepRemaining -= const Duration(seconds: 1);
      if (_sleepRemaining <= Duration.zero) {
        t.cancel();
        _sleepTimer = null;
        _sleepRemaining = Duration.zero;
        unawaited(pause());
        _log('[sleep] 定时到点，已暂停');
      }
      notifyListeners();
    });
    _log('[sleep] 定时 $minutes 分钟');
    notifyListeners();
  }

  Future<void> cancelSleepTimer() => setSleepTimer();

  // ==================================================== 地址失效自愈（P-05）

  /// 播放器报错 → 静默重取地址 → seek 回原进度续播（R5 / **P-05**）。
  Future<bool> _recover({
    bool forceRefresh = true,
    String reason = '播放中断',
  }) async {
    if (_recovering || !hasSession || _album == null) return false;
    if (_recoverTries >= 3) {
      _error = '播放失败：地址多次刷新仍不可用，请稍后重试';
      _loading = false;
      _recovering = false;
      _log('[recover] 放弃：已连续失败 $_recoverTries 次');
      notifyListeners();
      return false;
    }

    _recovering = true;
    _recoverTries++;
    final mySession = _session;
    final resumeMs = _lastKnown.inMilliseconds;
    final album = _album!;
    final chapter = _chapters[_index];
    _loading = true;
    _error = null;
    _log('[recover] $reason → 重取地址（第 $_recoverTries 次）@${resumeMs}ms');
    notifyListeners();

    try {
      final bvid = chapter.bvid.isEmpty ? album.bvid : chapter.bvid;
      if (chapter.cid != 0) playUrl.invalidate(bvid, chapter.cid);
      final candidates = await playUrl.resolve(
        bvid: bvid,
        cid: chapter.cid,
        quality: _quality,
        forceRefresh: forceRefresh,
      );
      if (mySession != _session) return false;

      var opened = false;
      for (var i = 0; i < candidates.length; i++) {
        try {
          await engine.open(
            url: candidates[i],
            headers: playUrl.headersFor(bvid),
            autoplay: true,
            startAt: Duration(milliseconds: resumeMs),
          );
          opened = true;
          break;
        } catch (e) {
          _log('[recover] 候选 $i 失败：$e');
          await engine.stop();
        }
      }
      if (!opened) throw StateError('重取地址后仍无法打开');
      if (mySession != _session) return false;

      _recoverFloor = Duration(milliseconds: resumeMs);
      _error = null;
      _watchPos = positionTick.value;
      _watchAt = DateTime.now();
      _pushBridge(force: true);
      _log('[recover] 自愈成功，续播 ${resumeMs}ms');
      return true;
    } catch (e) {
      _log('[recover] 失败：$e');
      return false;
    } finally {
      _recovering = false;
      if (mySession == _session) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  /// **P-05 演练入口**：把内存里的地址作废并让当前音源立即失效，
  /// 模拟「播放地址过期（403）」，验证自动重取 + 回原进度续播。
  Future<void> debugExpireCurrentUrl() async {
    if (!hasSession || _album == null) return;
    final chapter = _chapters[_index];
    final bvid = chapter.bvid.isEmpty ? _album!.bvid : chapter.bvid;
    if (chapter.cid != 0) playUrl.invalidate(bvid, chapter.cid);
    _log('[debug] 手动作废地址 $bvid/${chapter.cid}');
    final broken =
        'https://0.0.0.0:1/expired-${DateTime.now().millisecondsSinceEpoch}.m4s';
    try {
      await engine.open(
        url: broken,
        headers: playUrl.headersFor(bvid),
        autoplay: true,
        startAt: Duration.zero, // 保留 _lastKnown，交给 _recover 接回
      );
    } catch (_) {
      // open 直接抛错也会走 errors 流
    }
  }

  // ==================================================== 断流看门狗（长音频）

  /// 播放开始时才拉起，暂停/播完即取消：空闲不空转，也避免测试残留 Timer。
  void _ensureWatchdog() {
    if (_disposed || _watchdog != null) return;
    _watchPos = positionTick.value;
    _watchAt = DateTime.now();
    _watchdog = Timer.periodic(const Duration(seconds: 5), (_) => _runWatchdog());
  }

  void _runWatchdog() {
    if (_disposed || _album == null || !_mediaReady) return;
    if (_recovering || _loading || _buffering || !_playing) {
      _watchPos = positionTick.value;
      _watchAt = DateTime.now();
      return;
    }
    final pos = positionTick.value;
    if (pos != _watchPos) {
      _watchPos = pos;
      _watchAt = DateTime.now();
      return;
    }
    if (DateTime.now().difference(_watchAt) > const Duration(seconds: 40)) {
      _log('[watchdog] 播放停滞 >40s，触发自动重连');
      _watchAt = DateTime.now();
      unawaited(_recover(reason: '看门狗：进度停滞'));
    }
  }

  // ================================================================ 引擎事件

  void _bindEngine(PlayerEngine e) {
    _subs
      ..add(e.position.listen(_onPosition))
      ..add(e.duration.listen((d) {
        if (d > Duration.zero && d != _duration) {
          _duration = d;
          notifyListeners();
          _pushBridge(force: true);
        }
      }))
      ..add(e.playing.listen(_onPlaying))
      ..add(e.buffering.listen((b) {
        if (b != _buffering) {
          _buffering = b;
          notifyListeners();
        }
      }))
      ..add(e.completed.listen((_) => unawaited(_onCompleted())))
      ..add(e.errors.listen((msg) {
        _log('[engine] error: $msg');
        if (_loading || _recovering || !hasSession) return;
        unawaited(_recover(reason: '播放器报错：$msg'));
      }));
  }

  void _onPosition(Duration p) {
    if (_loading || _disposed) return;
    if (p <= Duration.zero) return; // 换源瞬间的 0 不可信，不覆盖续播点
    _position = p;
    _lastKnown = p;
    positionTick.value = p;

    // 真实收听时长（M8 统计埋点）：只累加「正常前进」的增量
    if (_playing) {
      final delta = p - _tallyPos;
      if (delta > Duration.zero && delta < const Duration(seconds: 6)) {
        _tally += delta;
      }
    }
    _tallyPos = p;

    final floor = _recoverFloor;
    if (floor != null && p >= floor + const Duration(seconds: 3)) {
      _recoverFloor = null;
      _recoverTries = 0; // 自愈确认成功，放开重试预算
    }

    _saveIfDue();
    _pushMini();
    _pushBridge();
  }

  void _onPlaying(bool v) {
    if (v == _playing || _disposed) return;
    _playing = v;
    _watchPos = positionTick.value;
    _watchAt = DateTime.now();
    if (v) {
      _ensureWatchdog();
    } else {
      _watchdog?.cancel();
      _watchdog = null;
      unawaited(_saveNow());
      unawaited(_commitTally());
    }
    _pushBridge(force: true);
    _pushMini(force: true);
    notifyListeners();
  }

  /// 自然播完一章（**分 P 连播** + 播放模式 + 「本章结束」开关）
  Future<void> _onCompleted() async {
    if (_loading || _recovering || !hasSession || _disposed) return;
    final dur = _duration;
    // media_kit 换源时可能抛一次伪 completed：位置没到结尾就忽略（abts 同款坑）
    if (dur > Duration.zero && positionTick.value < dur - const Duration(seconds: 3)) {
      return;
    }

    unawaited(_saveNow());

    if (_stopAtChapterEnd) {
      // 「本章结束」：回退片尾便于重听，进度指向下一章开头
      await _rewindTail();
      await pause();
      unawaited(_advanceProgressToNext());
      _log('[completed] 本章结束（定时/开关），已暂停');
      notifyListeners();
      return;
    }

    if (_mode == PlayMode.loopOne) {
      await seek(Duration.zero);
      await play();
      return;
    }
    if (hasNext) {
      await playChapterAt(_index + 1);
      return;
    }
    if (_mode == PlayMode.loopAll && _chapters.isNotEmpty) {
      await playChapterAt(0);
      return;
    }
    await _rewindTail();
    await pause();
    _log('[completed] 全部播完，已暂停');
    notifyListeners();
  }

  /// 播到片尾回退一小段（否则流已在 EOF，再按播放毫无反应）。
  /// **刻意不落库**：这不是用户真实收听进度。
  Future<void> _rewindTail() async {
    if (_engine == null) return;
    final pos = _position;
    if (pos <= const Duration(seconds: 15)) return;
    final back = pos - const Duration(seconds: 15);
    try {
      await engine.seek(back);
      _position = back;
      positionTick.value = back;
      // _lastKnown 保持在片尾：落库用的是它，续播点不被回退污染
    } catch (e) {
      _log('[completed] 回退片尾失败：$e');
    }
  }

  /// 「本章结束」后把续播点推进到下一章开头
  Future<void> _advanceProgressToNext() async {
    if (!hasNext || _album == null) return;
    final nextChapter = _chapters[_index + 1];
    final duration = nextChapter.durationSec;
    await store.save(
      albumId: _album!.id,
      chapterId: nextChapter.id,
      chapterTitle: nextChapter.title,
      positionSec: 0,
      durationSec: duration,
    );
    await store.touchShelf(
      albumId: _album!.id,
      chapterId: nextChapter.id,
      positionSec: 0,
      totalChapters: _chapters.length,
    );
    _position = Duration.zero;
    _lastKnown = Duration.zero;
    positionTick.value = Duration.zero;
    _index = _index + 1;
    _mediaReady = false;
  }

  // ================================================================ 进度落库

  void _saveIfDue() {
    if (_loading || _recovering || !hasSession) return;
    if (DateTime.now().difference(_lastSaveAt) < saveInterval) return;
    unawaited(_saveNow());
  }

  /// 写 `play_history` + 同步书架进度 + 提交收听时长埋点。
  Future<void> _saveNow() async {
    if (_loading || _recovering || !hasSession || _album == null) return;
    final chapter = _chapters[_index];
    final pos = _lastKnown;
    var durationMs = _duration.inMilliseconds;
    if (durationMs <= 0) durationMs = chapter.durationSec * 1000;
    if (durationMs <= 0) return;

    _lastSaveAt = DateTime.now();
    await store.save(
      albumId: _album!.id,
      chapterId: chapter.id,
      chapterTitle: chapter.title,
      positionSec: pos.inSeconds,
      durationSec: (durationMs / 1000).round(),
    );
    await store.touchShelf(
      albumId: _album!.id,
      chapterId: chapter.id,
      positionSec: pos.inSeconds,
      totalChapters: _chapters.length,
    );
    await _commitTally();
  }

  Future<void> _commitTally() async {
    if (_tally < const Duration(seconds: 1) || _album == null) return;
    final seconds = _tally.inSeconds;
    _tally = Duration.zero;
    await store.addPlaySeconds(
      albumId: _album!.id,
      categoryId: _album!.categoryId,
      seconds: seconds,
    );
  }

  /// 立即写盘（章节切换 / 暂停 / 拖动 / 退出前台时调用）
  Future<void> flushProgress() => _saveNow();

  // ============================================================ 系统与生命周期

  void _bindMedia() {
    _media.bind(
      onPlay: play,
      onPause: pause,
      onSeek: (d) async => seek(d),
      onNext: next,
      onPrev: previous,
      onStop: stop,
      onFastForward: () => seekRelative(15),
      onRewind: () => seekRelative(-15),
    );
  }

  void _pushBridge({bool force = false}) {
    if (_disposed) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastBridgePush) < const Duration(milliseconds: 500)) {
      return;
    }
    _lastBridgePush = now;
    final album = _album;
    _media.publish(MediaSnapshot(
      active: album != null,
      playing: _playing,
      position: _position,
      duration: _duration,
      albumTitle: album?.title ?? '',
      chapterTitle: currentChapter?.title ?? '',
      coverUrl: album?.coverUrl ?? '',
      hasNext: hasNext,
      hasPrev: hasPrev,
    ));
  }

  void _pushMini({bool force = false}) {
    if (_disposed) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastMiniPush) < const Duration(seconds: 1)) {
      return;
    }
    _lastMiniPush = now;
    final album = _album;
    final chapter = currentChapter;
    miniPlayer.update(MiniPlayerState(
      hasTask: album != null,
      albumTitle: album?.title ?? '',
      chapterTitle: chapter == null
          ? (album == null ? '' : '准备播放')
          : chapter.title,
      coverUrl: album?.coverUrl ?? '',
      progress: progress,
      playing: _playing,
    ));
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
    _pushMini(force: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 退到后台 / 被回收前立刻落库，保证下次续播精确到秒（P-03）
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(flushProgress());
    }
  }

  void _log(String msg) => log?.call(msg);

  @override
  void dispose() {
    if (_disposed) return; // 幂等：restart / 测试里可能重复调用
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    _watchdog?.cancel();
    _sleepTimer?.cancel();
    positionTick.dispose();
    unawaited(_focus.abandon());
    if (_engine != null) unawaited(_engine!.dispose());
    super.dispose();
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(StringProperty('album', _album?.title))
      ..add(IntProperty('index', _index))
      ..add(FlagProperty('playing', value: _playing, ifTrue: 'playing'))
      ..add(FlagProperty('loading', value: _loading, ifTrue: 'loading'))
      ..add(DiagnosticsProperty<PlayMode>('mode', _mode))
      ..add(DoubleProperty('rate', _rate));
  }
}
