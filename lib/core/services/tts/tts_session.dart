import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/reader_book.dart';
import '../player/audio_focus.dart';
import '../player/media_bridge.dart';
import '../player/playback_arbiter.dart';
import '../reader/book_store.dart';
import '../reader/reader_activity_store.dart';
import 'tts_engine.dart';
import 'tts_settings_store.dart';

/// 阅读页提供给 TTS 的端口：取段落、高亮、读取当前位置。
abstract class TtsReaderPort {
  /// 当前渲染章节索引。
  Future<int> currentChapter();

  /// 确保指定章节已渲染并提取正文段落（纯文本）。
  Future<List<String>> paragraphsOf(int chapterIndex);

  /// 高亮并滚动到指定段落。
  Future<void> highlight(int paragraphIndex);

  Future<void> clearHighlight();

  /// 当前可见区域内的段落序号（取不到返回 0）。
  Future<int> visibleParagraph();
}

/// 听书会话（docs/reader-design.md §5.2）：
/// 段落队列 → 逐段朗读 → 高亮跟随 → 跨章续读 → 断点落盘 → 后台媒体会话。
class TtsSession extends ChangeNotifier {
  TtsSession({
    required this.settings,
    required this.books,
    required this.activity,
    required this.arbiter,
    required this.engineFactory,
    this.focus,
  }) {
    arbiter.registerTts(
      bind: _bindMediaControls,
      bindFocus: _bindFocus,
      stop: stop,
    );
  }

  final TtsSettingsStore settings;
  final ReaderBookStore books;
  final ReaderActivityStore activity;
  final PlaybackArbiter arbiter;
  final TtsEngine Function(TtsEngineKind kind) engineFactory;

  /// 可注入用于单测；默认使用全局原生焦点通道。
  final AudioFocus? focus;

  TtsReaderPort? _port;
  ReaderBook? _book;
  String? _bookId;
  String Function(int index)? _chapterTitleOf;

  TtsEngine? _engine;
  TtsEngineKind _engineKind = TtsEngineKind.edge;

  List<String> _paragraphs = const [];
  int _chapterIndex = 0;
  int _paraIndex = 0;

  bool _active = false;
  bool _navigating = false;
  bool _playing = false;
  bool _paused = false;
  bool _abortedByPause = false;
  bool _stopAfterChapter = false;
  bool _interrupted = false;
  String? _error;

  int _runId = 0;
  Completer<void>? _pauseGate;
  DateTime? _playStartedAt;
  int _pendingLogSec = 0;

  Duration _sleepRemaining = Duration.zero;
  Timer? _sleepTimer;

  /// 与阅读页解绑后待续的章节（页面不存在时无法提取新章节段落）。
  int? _pendingChapter;

  // ---------------------------------------------------------------- 只读状态
  bool get active => _active;

  /// 正在为 TTS 切章/取段落（阅读页据此忽略自动定位事件，避免抢回位置）。
  bool get navigating => _navigating;
  bool get playing => _playing && !_paused && _active;
  bool get paused => _paused && _active;
  String? get error => _error;
  String? get bookId => _bookId;
  int get chapterIndex => _chapterIndex;
  int get paragraphIndex => _paraIndex;
  int get paragraphCount => _paragraphs.length;
  TtsEngineKind get engineKind => _engineKind;
  Duration get sleepRemaining => _sleepRemaining;
  bool get hasSleepTimer => _sleepTimer != null || _stopAfterChapter;
  bool get stopAfterChapter => _stopAfterChapter;
  String get chapterTitle =>
      _chapterTitleOf?.call(_chapterIndex) ?? '第${_chapterIndex + 1}章';
  String get bookTitle => _book?.title ?? '';

  /// 阅读页打开时绑定端口（退出页面只解绑，不中断朗读）。
  void bindReader({
    required ReaderBook book,
    required TtsReaderPort port,
    required String Function(int index) chapterTitleOf,
  }) {
    _book = book;
    _bookId = book.id;
    _port = port;
    _chapterTitleOf = chapterTitleOf;
    if (_active) {
      // 回到阅读页：补上高亮；若因离页停在章末，续读下一章。
      unawaited(_syncHighlight());
      final pending = _pendingChapter;
      if (pending != null && _paused) {
        _pendingChapter = null;
        unawaited(resume(chapterOverride: pending));
      }
    }
  }

  void unbindReader() {
    _port = null;
    _chapterTitleOf = null;
  }

  // ---------------------------------------------------------------- 播放控制

  /// 开始听书：优先从断点续听；未指定则从当前可见段落。
  Future<void> start({
    int? chapterIndex,
    int? paraIndex,
    bool fromBookmark = true,
  }) async {
    final book = _book;
    final port = _port;
    if (book == null || port == null) return;
    if (_active && _bookId == book.id) {
      if (_paused) await resume();
      return;
    }
    if (_active) await stop();

    _error = null;
    _engineKind = settings.engine;
    var chapter = chapterIndex;
    var para = paraIndex;
    if (chapter == null && fromBookmark && book.lastTtsParaIndex != null) {
      chapter = book.lastChapterIndex;
      para = book.lastTtsParaIndex;
    }
    chapter ??= await port.currentChapter();
    para ??= await port.visibleParagraph();

    await arbiter.claimTts();
    _active = true;
    _paused = false;
    _playing = false;
    _chapterIndex = chapter;
    _paraIndex = para;
    _stopAfterChapter = false;
    _playStartedAt = DateTime.now();
    notifyListeners();

    try {
      await _ensureEngine();
    } catch (e) {
      // 引擎不可用（如设备缺少系统语音引擎）：落到可读错误态，而不是抛未捕获异常。
      _error = e is TtsException ? e.message : '$e';
      _playing = false;
      _paused = true;
      _playStartedAt = null;
      notifyListeners();
      return;
    }
    _runId++;
    unawaited(_run(_runId, _chapterIndex, _paraIndex));
  }

  Future<void> resume({int? chapterOverride}) async {
    if (!_active) return;
    if (!_paused && _playing) return;
    _paused = false;
    _error = null;
    if (chapterOverride != null) _chapterIndex = chapterOverride;
    _pendingChapter = null;
    _pauseGate?.complete();
    _pauseGate = null;
    _playStartedAt = DateTime.now();
    notifyListeners();
    _runId++;
    unawaited(_run(_runId, _chapterIndex, _paraIndex));
  }

  Future<void> pause() async {
    if (!_active) return;
    // 任何状态（含错误态/已暂停）都必须能暂停并清除错误提示。
    _paused = true;
    _error = null;
    _abortedByPause = true;
    await _engine?.stop();
    await _accumulate();
    _playStartedAt = null;
    _playing = false;
    _publishMedia();
    notifyListeners();
  }

  Future<void> toggle() => playing ? pause() : resume();

  /// 手动跳段（通知栏上一段/下一段、控制条）。
  Future<void> skipParagraph(int delta) async {
    if (!_active) return;
    final target = _paraIndex + delta;
    if (target < 0) {
      if (_chapterIndex <= 0) return;
      _chapterIndex--;
      _paraIndex = 9999; // 交给 _run 取章末
    } else if (target >= _paragraphs.length) {
      if (_chapterIndex >= (_book?.chapterCount ?? 1) - 1) return;
      _chapterIndex++;
      _paraIndex = 0;
    } else {
      _paraIndex = target;
    }
    await _restartLoop();
  }

  /// 用户手动翻页/跳章：TTS 位置同步（先停再取新章段落）。
  Future<void> repositionTo(int chapterIndex, int paragraphIndex) async {
    if (!_active || (chapterIndex == _chapterIndex && paragraphIndex == _paraIndex)) {
      return;
    }
    _chapterIndex = chapterIndex;
    _paraIndex = paragraphIndex;
    await _restartLoop();
  }

  /// 设置页/控制条改了语速音调后即时重载当前段。
  ///
  /// 系统引擎参数设置失败（返回 0 / 平台拒绝）不代表引擎不可用，也不能中断
  /// 当前朗读或弹红字：这里静默降级沿用旧参数，真正不可用由初始化与合成报错。
  Future<void> reloadParams() async {
    if (!_active || _engine == null) return;
    try {
      await _engine!.start(settings.params);
    } catch (e) {
      if (_engineKind != TtsEngineKind.system) rethrow;
      debugPrint('[tts:session] 系统引擎更新参数失败，沿用旧参数：$e');
      return;
    }
    await _restartLoop();
  }

  Future<void> switchEngine(TtsEngineKind kind) async {
    if (_engineKind == kind && _engine != null) return;
    await settings.setEngine(kind);
    if (!_active) {
      _engineKind = kind;
      notifyListeners();
      return;
    }
    _engineKind = kind;
    await _engine?.stop();
    await _engine?.dispose();
    _engine = null;
    await _ensureEngine();
    await _restartLoop();
  }

  Future<void> stop() async {
    if (!_active) return;
    _runId++;
    _active = false;
    _playing = false;
    _paused = false;
    _pendingChapter = null;
    _stopAfterChapter = false;
    _pauseGate?.complete();
    _pauseGate = null;
    _cancelSleepTimer();
    await _engine?.stop();
    await _accumulate();
    _playStartedAt = null;
    await _clearHighlight();
    final book = _book;
    if (book != null) {
      await _saveBookmark(book: book, chapter: _chapterIndex, para: _paraIndex);
    }
    arbiter.releaseTts();
    _publishMedia(active: false);
    notifyListeners();
  }

  Future<void> _restartLoop() async {
    // 先作废旧循环，再 stop：否则 stop 让旧 speak 返回后，旧循环会在
    // _runId 递增前抢先读过下一段（切语速后出现重复/错段朗读）。
    final runId = ++_runId;
    _pauseGate?.complete();
    _pauseGate = null;
    _paused = false;
    _possibleResumeTime();
    await _engine?.stop();
    await _accumulate();
    _playStartedAt = DateTime.now();
    notifyListeners();
    unawaited(_run(runId, _chapterIndex, _paraIndex));
  }

  void _possibleResumeTime() {
    // 暂停/跳段后继续时重新计时。
    _playStartedAt ??= DateTime.now();
  }

  // ---------------------------------------------------------------- 朗读主循环

  Future<void> _run(int runId, int chapter, int para) async {
    final port = _port;
    final book = _book;
    if (port == null || book == null) return;
    try {
      while (_active && runId == _runId) {
        _navigating = true;
        final list = await port.paragraphsOf(chapter);
        _navigating = false;
        if (!_active || runId != _runId) return;
        if (list.isEmpty) {
          throw const TtsException('empty_chapter', '本章没有可朗读的正文');
        }
        _paragraphs = list;
        var index = para;
        if (index == 9999) index = list.length - 1;
        if (index < 0) index = 0;
        if (index >= list.length) index = list.length - 1;
        _chapterIndex = chapter;
        _paraIndex = index;
        _recordListeningHistory(book, chapter);
        _publishMedia();
        notifyListeners();

        for (var i = index; i < list.length; i++) {
          if (!_active || runId != _runId) return;
          while (_paused) {
            _pauseGate ??= Completer<void>();
            await _pauseGate!.future;
            if (!_active || runId != _runId) return;
          }
          _paraIndex = i;
          notifyListeners();
          await _highlight(i);
          if (i + 1 < list.length) _engine?.prefetch(list[i + 1]);
          _playing = true;
          _publishMedia();
          notifyListeners();
          try {
            await _engine?.speak(list[i]);
          } on TtsException catch (e) {
            if (!_active || runId != _runId) return;
            if (_abortedByPause) {
              _abortedByPause = false;
              i--;
              continue;
            }
            // 合成/临时占用失败：静默暂停并留在当前段，不弹红字；初始化失败才提示引擎不可用。
            if (e.code != 'speak_failed') _error = e.message;
            _playing = false;
            _paused = true;
            await _accumulate();
            _playStartedAt = null;
            notifyListeners();
            return;
          }
          if (!_active || runId != _runId) return;
          if (_abortedByPause) {
            _abortedByPause = false;
            i--;
            continue;
          }
          _playing = false;
          await _saveBookmark(
            book: book,
            chapter: chapter,
            para: i,
            chapterCount: list.length,
          );
          if (_stopAfterChapter) {
            await pause();
            _stopAfterChapter = false;
            _cancelSleepTimer();
            notifyListeners();
            return;
          }
        }
        // 章末：跨章续读。
        if (chapter + 1 >= book.chapterCount) {
          _active = false;
          _playing = false;
          await _accumulate();
          _playStartedAt = null;
          await _clearHighlight();
          arbiter.releaseTts();
          _publishMedia(active: false);
          notifyListeners();
          return;
        }
        chapter++;
        para = 0;
        if (_port == null) {
          _pendingChapter = chapter;
          _paused = true;
          _playing = false;
          await _accumulate();
          _playStartedAt = null;
          notifyListeners();
          return;
        }
        await _saveBookmark(
          book: book,
          chapter: chapter,
          para: 0,
          chapterCount: list.length,
        );
      }
    } catch (e) {
      _navigating = false;
      if (!_active || runId != _runId) return;
      _error = e is TtsException ? e.message : '$e';
      _playing = false;
      _paused = true;
      await _accumulate();
      _playStartedAt = null;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------- 引擎/设置

  Future<void> _ensureEngine() async {
    if (_engine != null && _engineKind == settings.engine) {
      await _engine!.start(settings.params);
      return;
    }
    await _engine?.dispose();
    _engineKind = settings.engine;
    final engine = engineFactory(_engineKind);
    _engine = engine;
    await engine.start(settings.params);
  }

  // ---------------------------------------------------------------- 系统媒体
  void _bindMediaControls() {
    arbiter.media.bind(
      onPlay: resume,
      onPause: pause,
      onSeek: (position) async {},
      onNext: () => skipParagraph(1),
      onPrev: () => skipParagraph(-1),
      onStop: stop,
    );
    _publishMedia();
  }

  void _bindFocus() {
    final f = focus ?? AudioFocus.instance;
    f.onFocusInterrupted = () {
      if (!playing) return;
      _interrupted = true;
      unawaited(pause());
    };
    f.onFocusLost = () {
      _interrupted = false;
      unawaited(pause());
    };
    f.onFocusGained = () {
      if (!_interrupted) return;
      _interrupted = false;
      unawaited(resume());
    };
    f.onNoisy = () {
      _interrupted = false;
      unawaited(pause());
    };
    f.onFocusDucked = null;
  }

  void _publishMedia({bool? active}) {
    final book = _book;
    final isActive = active ?? _active;
    arbiter.media.publish(MediaSnapshot(
      active: isActive && book != null,
      playing: playing,
      position: Duration(seconds: 0),
      albumTitle: book?.title ?? '',
      chapterTitle: chapterTitle,
      hasNext: _chapterIndex < (_book?.chapterCount ?? 1) - 1,
      hasPrev: _chapterIndex > 0,
      speed: settings.rate,
    ));
  }

  // ---------------------------------------------------------------- 高亮
  Future<void> _syncHighlight() async {
    if (!_active) return;
    await _highlight(_paraIndex);
  }

  Future<void> _highlight(int index) async {
    final port = _port;
    if (port == null) return;
    try {
      _navigating = true;
      await port.highlight(index);
    } catch (e) {
      debugPrint('[tts] 高亮失败：$e');
    } finally {
      _navigating = false;
    }
  }

  Future<void> _clearHighlight() async {
    try {
      await _port?.clearHighlight();
    } catch (_) {}
  }

  // ---------------------------------------------------------------- 落盘/埋点
  Future<void> _saveBookmark({
    required ReaderBook book,
    required int chapter,
    required int para,
    int? chapterCount,
  }) async {
    final total = chapterCount ?? _paragraphs.length;
    final inChapter = total > 0 ? (para / total).clamp(0.0, 1.0) : 0.0;
    final chapters = book.chapterCount > 0 ? book.chapterCount : 1;
    final fraction =
        ((chapter + inChapter) / chapters).clamp(0.0, 1.0);
    await books.updateProgress(
      book.id,
      chapterIndex: chapter,
      fraction: fraction,
      ttsParaIndex: para,
    );
  }

  void _recordListeningHistory(ReaderBook book, int chapter) {
    activity.recordHistory(
      ReaderHistoryEntry(
        bookId: book.id,
        bookTitle: book.title,
        chapterTitle: _chapterTitleOf?.call(chapter) ?? '第${chapter + 1}章',
        mode: ReaderActivityMode.listening,
        at: DateTime.now(),
      ),
    );
  }

  Future<void> _accumulate() async {
    final started = _playStartedAt;
    if (started == null) return;
    _pendingLogSec += DateTime.now().difference(started).inSeconds;
    _playStartedAt = null;
    await _flushLog();
  }

  Future<void> _flushLog() async {
    final seconds = _pendingLogSec;
    final book = _book;
    if (seconds <= 0 || book == null) return;
    _pendingLogSec = 0;
    await activity.logDuration(
      bookId: book.id,
      durationSec: seconds,
      mode: ReaderActivityMode.listening,
    );
  }

  // ---------------------------------------------------------------- 睡眠定时
  Future<void> setSleepTimer({int? minutes}) async {
    _cancelSleepTimer();
    if (minutes == null) {
      _stopAfterChapter = false;
      notifyListeners();
      return;
    }
    if (minutes == 0) {
      _stopAfterChapter = true;
      notifyListeners();
      return;
    }
    _stopAfterChapter = false;
    _sleepRemaining = Duration(minutes: minutes);
    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      _sleepRemaining -= const Duration(seconds: 1);
      if (_sleepRemaining <= Duration.zero) {
        t.cancel();
        _sleepTimer = null;
        _sleepRemaining = Duration.zero;
        unawaited(stop());
      }
      notifyListeners();
    });
    notifyListeners();
  }

  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepRemaining = Duration.zero;
  }

  @override
  void dispose() {
    _runId++;
    _cancelSleepTimer();
    _pauseGate?.complete();
    unawaited(_engine?.dispose());
    unawaited(_flushLog());
    super.dispose();
  }
}
