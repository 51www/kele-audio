import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/reader_book.dart';
import '../player/audio_focus.dart';
import '../player/media_bridge.dart';
import '../player/playback_arbiter.dart';
import '../reader/book_store.dart';
import '../reader/reader_activity_store.dart';
import '../reader/reader_bridge.dart';
import 'tts_engine.dart';
import 'tts_settings_store.dart';
import 'tts_text_splitter.dart';

/// 阅读页提供给 TTS 的端口：取段落、高亮、读取当前位置。
abstract class TtsReaderPort {
  /// 当前渲染章节索引。
  Future<int> currentChapter();

  /// 确保指定章节已渲染并提取正文段落（纯文本）。
  Future<List<String>> paragraphsOf(int chapterIndex);

  /// 高亮指定段落；给定 [startChar]/[endChar] 时只高亮段内这一区间（一两句）。
  /// [scroll] 为 true 时同时滚动到该段。
  Future<void> highlight(
    int paragraphIndex, {
    bool scroll = true,
    int? startChar,
    int? endChar,
  });

  Future<void> clearHighlight();

  /// 当前可见区域内的段落序号（取不到返回 0）。
  Future<int> visibleParagraph();

  /// 当前可见段落；判定不出来返回 null，避免调用方误当成「章首第 0 段」。
  /// 默认沿用旧接口，阅读页会覆盖为 strict 实现。
  Future<int?> visibleParagraphStrict() async => visibleParagraph();

  /// 当前页第一句的锚点（段落 + 段内字符起点）；默认不支持，阅读页覆盖。
  Future<ReaderSentenceAnchor?> firstVisibleSentence({
    int? expectedChapter,
  }) async =>
      null;
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

  /// 当前 [_paragraphs] 所属章节（-1 = 无缓存）。
  int _paragraphsChapter = -1;
  int _chapterIndex = 0;
  int _paraIndex = 0;

  /// 当前朗读句在 [_paraIndex] 段内的起始字符下标。
  /// 切音色/引擎、暂停恢复等「原地续读」都从这一句重开，而不是退回段落开头。
  int _startChar = 0;

  /// 引擎是否已在后台预热（每次换书重置一次）。
  bool _warmDone = false;

  /// 阅读页最近一次下发的章节目录文案（离线时播放页仍能显示目录）。
  List<String> _chapterLabels = const [];

  bool _active = false;

  /// 切章取段落与高亮可能并发，必须用计数而不是单个 bool，
  /// 否则先完成的一方会把另一方还在进行中的导航标志清掉。
  int _navigating = 0;

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

  /// 进度条拖动中的会话状态：拖动开始先暂停，拖动只预览位置，
  /// 松手才一次性落盘并重启朗读，避免旧循环与预览位置互相抢。
  bool _seeking = false;
  int? _seekOriginalPara;
  bool _seekResumeAfter = false;

  /// 估算朗读时长的基准：1.0x 约每秒 4.5 个汉字，段间留 0.15 秒停顿。
  /// TTS 没有真实音频时间轴，进度/时长按本章正文字符数估算。
  static const double _baseCharsPerSecond = 4.5;
  static const double _paragraphPauseSeconds = 0.15;

  // ---------------------------------------------------------------- 只读状态
  bool get active => _active;

  /// 正在为 TTS 切章/取段落（阅读页据此忽略自动定位事件，避免抢回位置）。
  bool get navigating => _navigating > 0;
  bool get playing => _playing && !_paused && _active;
  bool get paused => _paused && _active;
  String? get error => _error;
  String? get bookId => _bookId;
  int get chapterIndex => _chapterIndex;
  int get paragraphIndex => _paraIndex;

  /// 当前朗读句在段内的起始字符下标（调试/测试用）。
  int get startChar => _startChar;

  int get paragraphCount => _paragraphs.length;
  TtsEngineKind get engineKind => _engineKind;
  Duration get sleepRemaining => _sleepRemaining;
  bool get seeking => _seeking;
  bool get hasSleepTimer => _sleepTimer != null || _stopAfterChapter;
  bool get stopAfterChapter => _stopAfterChapter;

  /// 阅读页是否仍挂载（关闭阅读页后无法抽取新章节正文）。
  bool get readerBound => _port != null;

  /// 章节目录文案（缺省时调用方回退「第 N 章」）。
  List<String> get chapterLabels => _chapterLabels;

  String get chapterTitle {
    final custom = _chapterTitleOf?.call(_chapterIndex);
    if (custom != null && custom.isNotEmpty) return custom;
    if (_chapterIndex >= 0 && _chapterIndex < _chapterLabels.length) {
      return _chapterLabels[_chapterIndex];
    }
    return '第${_chapterIndex + 1}章';
  }

  String get bookTitle => _book?.title ?? '';

  /// 本章从开头读到指定段的预计用时（按当前语速）。
  Duration estimatedTimeAtParagraph(int paragraphIndex) {
    if (_paragraphs.isEmpty) return Duration.zero;
    final end = paragraphIndex.clamp(0, _paragraphs.length);
    var chars = 0;
    for (var i = 0; i < end; i++) {
      chars += _paragraphs[i].replaceAll(RegExp(r'\s'), '').length;
    }
    final rate = settings.rate > 0 ? settings.rate : 1.0;
    final seconds = chars / (_baseCharsPerSecond * rate) +
        end * _paragraphPauseSeconds;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  Duration get estimatedChapterPosition =>
      estimatedTimeAtParagraph(_paraIndex);

  Duration get estimatedChapterTotal =>
      estimatedTimeAtParagraph(_paragraphs.length);

  /// 阅读页打开时绑定端口（退出页面只解绑，不中断朗读）。
  void bindReader({
    required ReaderBook book,
    required TtsReaderPort port,
    required String Function(int index) chapterTitleOf,
    List<String>? chapterTitles,
  }) {
    // 换书：清掉上一本的目录与段落缓存，避免断点/文案串书。
    if (_bookId != book.id) {
      _chapterLabels = const [];
      _paragraphs = const [];
      _paragraphsChapter = -1;
      _warmDone = false;
    }
    if (chapterTitles != null && chapterTitles.isNotEmpty) {
      _chapterLabels = List<String>.unmodifiable(chapterTitles);
    }
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

  /// 阅读页解析出目录后同步给会话：关掉阅读页后播放页/播放条仍显示章节名。
  void updateChapterTitles(String bookId, List<String> labels) {
    if (bookId != _bookId || labels.isEmpty) return;
    final next = List<String>.unmodifiable(labels);
    if (listEquals(next, _chapterLabels)) return;
    _chapterLabels = next;
    notifyListeners();
  }

  // ---------------------------------------------------------------- 播放控制

  /// 开始听书：优先从断点续听；未指定则从当前可见段落。
  /// [charIndex] 为起播段内第一句的字符起点（0 表示整段从头）。
  Future<void> start({
    int? chapterIndex,
    int? paraIndex,
    int charIndex = 0,
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
      charIndex = 0;
    }
    chapter ??= await port.currentChapter();
    para ??= await port.visibleParagraphStrict();
    para ??= await port.visibleParagraph();
    if (charIndex < 0) charIndex = 0;

    await arbiter.claimTts();
    _active = true;
    _paused = false;
    _playing = false;
    _chapterIndex = chapter;
    _paraIndex = para;
    _startChar = charIndex;
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
    unawaited(_run(_runId, _chapterIndex, _paraIndex, _startChar));
  }

  Future<void> resume({int? chapterOverride}) async {
    if (!_active) return;
    if (!_paused && _playing) return;
    if (_port == null &&
        (_paragraphsChapter != _chapterIndex || _paragraphs.isEmpty)) {
      // 没有阅读页、也没有本章正文缓存：无法抽取新章，保持暂停，
      // 由播放页提示「回到阅读页继续」（bindReader 会从 pendingChapter 续读）。
      _pendingChapter = _chapterIndex;
      _paused = true;
      _playing = false;
      _publishMedia();
      notifyListeners();
      return;
    }
    _paused = false;
    _error = null;
    if (chapterOverride != null) _chapterIndex = chapterOverride;
    _pendingChapter = null;
    _pauseGate?.complete();
    _pauseGate = null;
    _playStartedAt = DateTime.now();
    notifyListeners();
    _runId++;
    unawaited(_run(_runId, _chapterIndex, _paraIndex, _startChar));
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

  /// 控制条 / mini 条 / 听书播放页的播放键：先对齐阅读页当前可见段落，再恢复。
  /// 否则暂停后翻页，resume() 会沿用旧 [_paraIndex]，表现为「从章节开头重念」。
  Future<void> resumeFromView() async {
    if (!_active) return;
    final port = _port;
    if (port == null) {
      await resume();
      return;
    }
    int chapter;
    try {
      chapter = await port.currentChapter();
    } catch (_) {
      await resume();
      return;
    }
    // 播放键同样对齐到当前页首句：暂停后翻页/换段，不应退回段落开头重念。
    final anchor = await port.firstVisibleSentence(expectedChapter: chapter);
    // 暂停态只更新断点，由 resume() 统一开一轮循环，避免重复起播。
    if (_paused) {
      if (anchor != null) {
        await repositionTo(
          chapter,
          anchor.paragraph,
          charIndex: anchor.charIndex,
        );
      } else {
        final para = await port.visibleParagraphStrict();
        if (para != null && para >= 0) await repositionTo(chapter, para);
      }
    }
    await resume();
  }

  Future<void> toggle() => playing ? pause() : resumeFromView();

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
    _startChar = 0;
    await _restartLoop();
  }

  /// 章级跳转（播放页「上一章 / 下一章」与目录点选）。
  ///
  /// 阅读页挂载时直接换章续读；阅读页已关闭时无法抽取新章正文，
  /// 这里只记录目标章并暂停，回到阅读页后由 [bindReader] 从该章续读。
  Future<void> jumpChapter(int target) async {
    final book = _book;
    if (!_active || book == null) return;
    final maxIndex = book.chapterCount > 0 ? book.chapterCount - 1 : 0;
    final index = target.clamp(0, maxIndex);
    if (index == _chapterIndex) return;
    _chapterIndex = index;
    _paraIndex = 0;
    _startChar = 0;
    _pendingChapter = null;
    _paragraphs = const [];
    _paragraphsChapter = -1;
    _engine?.resetCache();
    if (_port == null) {
      _pendingChapter = index;
      if (!_paused) await pause();
      await _saveBookmark(book: book, chapter: index, para: 0, chapterCount: 0);
      _publishMedia();
      notifyListeners();
      return;
    }
    await _restartLoop();
  }

  /// 相对跳章（-1 上一章 / +1 下一章）。
  Future<void> stepChapter(int delta) async {
    if (delta == 0) return;
    await jumpChapter(_chapterIndex + delta);
  }

  /// 用户手动翻页/跳章：TTS 位置同步（先停再取新章段落）。
  ///
  /// 暂停中只更新断点位置、不开讲，等用户恢复时从新位置开始。
  Future<void> repositionTo(
    int chapterIndex,
    int paragraphIndex, {
    int? charIndex,
  }) async {
    if (!_active) return;
    final sameSpot =
        chapterIndex == _chapterIndex && paragraphIndex == _paraIndex;
    if (sameSpot && (charIndex == null || charIndex == _startChar)) return;
    _chapterIndex = chapterIndex;
    _paraIndex = paragraphIndex;
    // 同一段落只改句锚点；换段无锚点时从头读。
    _startChar = sameSpot && charIndex == null ? _startChar : (charIndex ?? 0);
    _pendingChapter = null;
    notifyListeners();
    if (_paused) {
      // 暂停中不开口，但高亮必须跟到新的真值段落；否则阅读页高亮
      // 会停在旧段，而播放页段数已变，两边看起来「对不上」。
      // 不滚动：翻页是用户在浏览，只在已可见的段落上换高亮。
      await _syncHighlight(scroll: false);
      return;
    }
    await _restartLoop();
  }

  /// 对齐到阅读页当前可见段落：播放中立即换段续讲，暂停中只记断点。
  Future<void> alignToView(int chapterIndex) async {
    final port = _port;
    if (!_active || port == null) return;
    int? para;
    try {
      para = await port.visibleParagraphStrict();
      para ??= await port.visibleParagraph();
    } catch (_) {
      return;
    }
    await repositionTo(chapterIndex, para);
  }

  // ---------------------------------------------------------------- 进度拖动

  /// 开始拖动进度条：先暂停正在进行的朗读，记录松手后是否要继续。
  Future<void> beginSeek() async {
    if (!_active || _seeking) return;
    _seeking = true;
    _seekOriginalPara = _paraIndex;
    _seekResumeAfter = playing;
    if (_seekResumeAfter) await pause();
    notifyListeners();
  }

  /// 拖动中预览目标段：只改断点与高亮，不启动引擎、不重启朗读循环。
  Future<void> previewSeekToParagraph(int paragraphIndex) async {
    if (!_active || !_seeking || _paragraphs.isEmpty) return;
    final target = paragraphIndex.clamp(0, _paragraphs.length - 1);
    if (target == _paraIndex) return;
    _paraIndex = target;
    _startChar = 0;
    _pendingChapter = null;
    notifyListeners();
    await _syncHighlight(scroll: true);
  }

  /// 松手提交：落盘断点；原本在播则只从目标段重启一轮朗读。
  Future<void> commitSeek() async {
    if (!_active || !_seeking) return;
    _seeking = false;
    final resume = _seekResumeAfter;
    _seekResumeAfter = false;
    _seekOriginalPara = null;
    final book = _book;
    if (book != null) {
      await _saveBookmark(
        book: book,
        chapter: _chapterIndex,
        para: _paraIndex,
        chapterCount: _paragraphs.length,
      );
    }
    if (resume) {
      await _restartLoop();
    } else {
      notifyListeners();
    }
  }

  /// 拖动被中断（如离开播放页）：回到拖动前位置，并恢复原播放状态。
  Future<void> cancelSeek() async {
    if (!_active || !_seeking) return;
    _seeking = false;
    final original = _seekOriginalPara;
    final resume = _seekResumeAfter;
    _seekOriginalPara = null;
    _seekResumeAfter = false;
    if (original != null && original != _paraIndex) {
      _paraIndex = original;
      _startChar = 0;
      await _syncHighlight(scroll: false);
      notifyListeners();
    }
    if (resume) await _restartLoop();
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
    // 等后台预热初始化结束再换引擎，避免两处同时创建 Player。
    await _engineInit;
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
    try {
      await _ensureEngine();
    } catch (e) {
      // 新引擎不可用（如系统语音缺失）：落到可读错误态，允许用户再切回其它引擎。
      _error = e is TtsException ? e.message : '$e';
      _playing = false;
      _paused = true;
      _playStartedAt = null;
      _publishMedia();
      notifyListeners();
      return;
    }
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
    unawaited(_run(runId, _chapterIndex, _paraIndex, _startChar));
  }

  void _possibleResumeTime() {
    // 暂停/跳段后继续时重新计时。
    _playStartedAt ??= DateTime.now();
  }

  /// 跨章续读：末章结束整轮，否则切到下一章并落盘断点。
  ///
  /// 返回下一章索引；返回 null 表示 [_run] 应结束（末章 / 阅读页已关闭）。
  /// 空章（抽取不到正文）也复用本方法，确保不会卡在当前章。
  Future<int?> _advanceChapter(int chapter, int chapterCount) async {
    final book = _book;
    if (book == null) return null;
    if (chapter + 1 >= book.chapterCount) {
      _active = false;
      _playing = false;
      await _accumulate();
      _playStartedAt = null;
      await _clearHighlight();
      arbiter.releaseTts();
      _publishMedia(active: false);
      notifyListeners();
      return null;
    }
    final next = chapter + 1;
    _chapterIndex = next;
    _paraIndex = 0;
    _startChar = 0;
    _engine?.resetCache();
    if (_port == null) {
      // 阅读页已关闭：无法抽取新章正文，等回到阅读页再续读。
      _pendingChapter = next;
      _paused = true;
      _playing = false;
      await _accumulate();
      _playStartedAt = null;
      notifyListeners();
      return null;
    }
    await _saveBookmark(
      book: book,
      chapter: next,
      para: 0,
      chapterCount: chapterCount,
    );
    return next;
  }

  /// 播放当前句时提前合成后续数句（含跨段首句），把网络往返与播放重叠起来。
  /// 只预取「下几句」，当前句仍走 speak，避免缓存命中顺序错乱。
  void _prefetchAhead({
    required List<String> paragraphs,
    required int paragraphIndex,
    required List<TtsTextSegment> segments,
    required int segmentIndex,
    required TtsTextSplitter splitter,
    int depth = 2,
  }) {
    final engine = _engine;
    if (engine == null) return;
    var remaining = depth;
    for (var s = segmentIndex + 1;
        s < segments.length && remaining > 0;
        s++, remaining--) {
      engine.prefetch(segments[s].text);
    }
    for (var i = paragraphIndex + 1;
        i < paragraphs.length && remaining > 0;
        i++) {
      for (final segment in splitter.split(paragraphs[i])) {
        if (remaining <= 0) break;
        engine.prefetch(segment.text);
        remaining--;
      }
    }
  }

  // ---------------------------------------------------------------- 朗读主循环

  Future<void> _run(int runId, int chapter, int para, int startChar) async {
    final book = _book;
    if (book == null) return;
    try {
      while (_active && runId == _runId) {
        // 每章重新读取：朗读过程中阅读页可能挂载/关闭。
        final port = _port;
        List<String> list;
        if (port != null) {
          _beginNavigate();
          try {
            list = await port.paragraphsOf(chapter);
          } finally {
            _endNavigate();
          }
          if (!_active || runId != _runId) return;
          if (list.isEmpty) {
            // 整章抽取不到正文（例如全章只有一个单行数字页码，被正文抽取
            // 的长度过滤丢弃）：不报错卡住，直接跳过本章续读下一章。
            final next = await _advanceChapter(chapter, 0);
            if (next == null) return;
            chapter = next;
            para = 0;
            // 句锚点只对起播章有效，跨章后必须从新章段首开始。
            startChar = 0;
            continue;
          }
          _paragraphs = list;
          _paragraphsChapter = chapter;
        } else {
          // 阅读页关闭后无法抽取段落：仅能续读已缓存的当前章，
          // 跨章需回阅读页载入正文（由 bindReader 的 pendingChapter 续读）。
          if (_paragraphsChapter != chapter || _paragraphs.isEmpty) {
            _chapterIndex = chapter;
            _pendingChapter = chapter;
            _playing = false;
            _paused = true;
            await _accumulate();
            _playStartedAt = null;
            _publishMedia();
            notifyListeners();
            return;
          }
          list = _paragraphs;
        }
        var index = para;
        if (index == 9999) index = list.length - 1;
        if (index < 0) index = 0;
        if (index >= list.length) index = list.length - 1;
        _chapterIndex = chapter;
        _paraIndex = index;
        _publishMedia();
        notifyListeners();

        // 起播段按句锚点跳过之前已经读过的句子；后续段落从完整段首开始。
        var resumeChar = startChar < 0 ? 0 : startChar;
        // 一句一片段：标点即句界，续读时才能精确回到当前这一句。
        const splitter = TtsTextSplitter.perSentence();
        for (var i = index; i < list.length; i++) {
          if (!_active || runId != _runId) return;
          _paraIndex = i;
          // 朗读期间 _playing 保持 true：短句间不再逐句 rebuild 整页，
          // 也避免段间短暂 false 时点播放键被当成 resume 而重开一轮朗读。
          _playing = true;
          _publishMedia();
          notifyListeners();
          // 逐句送给引擎：首请求体量最小，高亮精确到句；段落下标仍是
          // 断点/进度/UI 的唯一坐标，句首偏移只用于续读定位。
          final segments = splitter.split(list[i]);
          if (segments.isEmpty) continue;
          var firstSegment = 0;
          if (i == index && resumeChar > 0) {
            final found = segments.indexWhere((seg) => seg.end > resumeChar);
            if (found > 0) firstSegment = found;
          }
          for (var s = firstSegment; s < segments.length; s++) {
            if (!_active || runId != _runId) return;
            while (_paused) {
              _pauseGate ??= Completer<void>();
              await _pauseGate!.future;
              if (!_active || runId != _runId) return;
            }
            final segment = segments[s];
            // 记住当前句首：切音色/引擎、暂停恢复时从这里续读而不是段落开头。
            _startChar = segment.start;
            // 立刻预取后续两句（首句也一样）：合成与 WebView 高亮、当前句播放
            // 重叠进行，避免播完才现场合成造成「念几句停一下」。
            _prefetchAhead(
              paragraphs: list,
              paragraphIndex: i,
              segments: segments,
              segmentIndex: s,
              splitter: splitter,
            );
            final highlight = _highlight(
              i,
              startChar: segment.start,
              endChar: segment.end,
            );
            final speaking = _engine?.speak(segment.text);
            try {
              // 高亮往返与出声并行：高亮慢时不会先空出一段再开始朗读。
              if (speaking != null) {
                await Future.wait<void>([highlight, speaking]);
              } else {
                await highlight;
              }
            } on TtsException catch (e) {
              if (!_active || runId != _runId) return;
              if (_abortedByPause) {
                _abortedByPause = false;
                s--;
                continue;
              }
              // 合成/临时占用失败：静默暂停并留在当前短句，不弹红字。
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
              s--;
              continue;
            }
          }
          // 本段读完，下一段从头开始；句锚点只作用于起播段。
          resumeChar = 0;
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
        final next = await _advanceChapter(chapter, list.length);
        if (next == null) return;
        chapter = next;
        para = 0;
        // _advanceChapter 只重置了会话字段；循环参数里的旧章句锚点也必须清掉，
        // 否则会用上一章的字符偏移跳过新章开头（音字对不上、听起来像断了一截）。
        startChar = 0;
      }
    } catch (e) {
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

  /// 阅读页就绪后后台预热：提前初始化播放内核、预合成当前页首句。
  /// 这样点耳机时 speak 常能直接命中缓存，省掉首次网络往返与本地初始化。
  /// 只做一次且仅在未开始听书时执行；任何失败都静默忽略，不影响正常起播。
  Future<void> warmUp() async {
    if (_warmDone || _active || _port == null) return;
    final book = _book;
    if (book == null || !book.ttsAllowed) return;
    _warmDone = true;
    if (_engineInit != null) return;
    try {
      await _ensureEngine();
    } catch (_) {
      return;
    }
    final port = _port;
    if (port == null || _active) return;
    try {
      final chapter = await port.currentChapter();
      var anchor = await port.firstVisibleSentence(expectedChapter: chapter);
      anchor ??= ReaderSentenceAnchor(
        paragraph: await port.visibleParagraphStrict() ?? 0,
        charIndex: 0,
      );
      final paragraphs = await port.paragraphsOf(chapter);
      if (anchor.paragraph < 0 || anchor.paragraph >= paragraphs.length) return;
      final segments = const TtsTextSplitter.perSentence()
          .split(paragraphs[anchor.paragraph]);
      if (segments.isEmpty) return;
      final charIndex = anchor.charIndex;
      final index = segments.indexWhere((s) => s.end > charIndex);
      _engine?.prefetch(segments[index < 0 ? 0 : index].text);
    } catch (_) {
      // 预热失败不影响点耳机后的正常朗读。
    }
  }

  Future<void>? _engineInit;

  Future<void> _ensureEngine() {
    final pending = _engineInit;
    if (pending != null) return pending;
    final future = _initEngine().whenComplete(() => _engineInit = null);
    _engineInit = future;
    return future;
  }

  Future<void> _initEngine() async {
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
      // 听书无连续进度（position 恒 0）：不让它参与「走表」外推判断，
      // 否则每切一段外推偏差就超阈值 → 反复重推 playbackState → 通知栏「叮」。
      trackPosition: false,
    ));
  }

  // ---------------------------------------------------------------- 高亮
  void _beginNavigate() => _navigating++;

  void _endNavigate() {
    if (_navigating > 0) _navigating--;
  }

  Future<void> _syncHighlight({bool scroll = true}) async {
    if (!_active) return;
    await _highlight(_paraIndex, scroll: scroll);
  }

  Future<void> _highlight(
    int index, {
    bool scroll = true,
    int? startChar,
    int? endChar,
  }) async {
    final port = _port;
    if (port == null) return;
    _beginNavigate();
    try {
      await port.highlight(
        index,
        scroll: scroll,
        startChar: startChar,
        endChar: endChar,
      );
    } catch (e) {
      debugPrint('[tts] 高亮失败：$e');
    } finally {
      _endNavigate();
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
