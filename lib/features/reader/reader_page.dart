import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../../app/route_observer.dart';
import '../../app/theme/app_tokens.dart';
import '../../core/domain/reader_book.dart';
import '../../core/services/reader/book_file_store.dart';
import '../../core/services/reader/book_store.dart';
import '../../core/services/reader/reader_activity_store.dart';
import '../../core/services/reader/reader_bridge.dart';
import '../../core/services/reader/reader_import_service.dart';
import '../../core/services/reader/reader_progress_store.dart';
import '../../core/services/reader/reader_typography.dart';
import '../../core/services/reader/pdf_page_map.dart';
import '../../core/services/reader/reading_duration_clock.dart';
import '../../core/services/tts/tts_session.dart';
import '../../core/services/tts/tts_settings_store.dart';
import 'reader_settings_sheet.dart';
import 'reader_toc_sheet.dart';
import 'reader_tts_bar.dart';

/// 阅读页（M9.2）：foliate-js 渲染容器 + 工具栏 + 目录 + 排版 + 续读。
///
/// 页面只通过 [ReaderBridge] 与 WebView 通信（协议见 docs/reader-design.md §4.2）。
class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.bookId});

  final String bookId;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage>
    with RouteAware, WidgetsBindingObserver {
  /// WebViewAssetLoader 的 https 域名（androidx.webkit 默认域）。
  static const _assetDomain = 'appassets.androidplatform.net';

  late final ReaderBridge _bridge;
  late final ReaderBookStore _books;
  late final ReaderActivityStore _activity;
  late final ReaderProgressStore _progress;
  late final ReaderTypographyStore _typography;
  late final TtsSession _tts;
  late final _BridgeTtsPort _ttsPort;

  final DateTime _openedAt = DateTime.now();
  final List<ReaderTocItem> _toc = [];
  ReaderLocation? _location;

  Uint8List? _bytes;
  bool _jsReady = false;
  bool _opening = false;
  bool _opened = false;
  bool _loading = true;
  bool _toolbarVisible = true;
  bool _refreshing = false;
  String? _error;
  String _styleKey = '';
  DateTime _lastSaveAt = DateTime.fromMillisecondsSinceEpoch(0);
  ReaderProgress? _resumeTarget;
  bool _resumeSettled = false;

  /// PDF 页码映射侧车（非 PDF 为 null）。
  PdfPageMap? _pdfPageMap;

  /// 已推给页脚渲染的页码文案，避免重复桥调用。
  String? _lastPageLabel;

  /// 阅读计时：只累加「当前路由可见 + 应用在前台 + 书籍已打开」的时长。
  /// 被听书播放页或任意二级页/弹层覆盖、退到后台都会暂停，重新露出后续算。
  final ReadingDurationClock _readingClock = ReadingDurationClock();
  ModalRoute<dynamic>? _route;
  bool _routeVisible = true;
  bool _appVisible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _books = context.read<ReaderBookStore>();
    _activity = context.read<ReaderActivityStore>();
    _progress = context.read<ReaderProgressStore>();
    _typography = context.read<ReaderTypographyStore>();
    _tts = context.read<TtsSession>();
    _bridge = ReaderBridge(
      onReady: () {
        _jsReady = true;
        _tryOpen();
      },
      onBookMeta: _onBookMeta,
      onRelocated: _onRelocated,
      onToc: (items) {
        if (!mounted) return;
        // 目录同步给听书会话：关掉阅读页后播放页/播放条仍能显示章节名。
        _tts.updateChapterTitles(widget.bookId, [
          for (final item in items) item.label,
        ]);
        setState(() {
          _toc
            ..clear()
            ..addAll(items);
        });
      },
      onTapCenter: () {
        if (!mounted) return;
        setState(() => _toolbarVisible = !_toolbarVisible);
      },
      onError: (message) {
        if (!mounted) return;
        setState(() {
          _error = '阅读引擎报错：$message';
          _loading = false;
        });
      },
      log: (message) => debugPrint('[reader] $message'),
    );
    _ttsPort = _BridgeTtsPort(_bridge);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == _route) return;
    if (_route != null) appRouteObserver.unsubscribe(this);
    _route = route;
    _routeVisible = route?.isCurrent ?? true;
    if (route != null) appRouteObserver.subscribe(this, route);
    _syncReadingClock();
  }

  /// 被任意页面（听书播放页、二级页、目录/排版弹层…）覆盖。
  @override
  void didPushNext() {
    _routeVisible = false;
    _syncReadingClock();
  }

  /// 覆盖页退出，阅读页重新露出。
  @override
  void didPopNext() {
    _routeVisible = true;
    _syncReadingClock();
    // 从播放页返回：以朗读段落为准重新锚定正文，避免停在用户浏览的旧页。
    if (_tts.active && _tts.bookId == widget.bookId) {
      unawaited(_anchorToTtsParagraph());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = state == AppLifecycleState.resumed;
    if (visible == _appVisible) return;
    _appVisible = visible;
    _syncReadingClock();
  }

  /// 可见性统一判断：路由在前台且当前露出才计时，其余一律暂停。
  void _syncReadingClock() {
    if (_routeVisible && _appVisible) {
      _readingClock.resume();
      return;
    }
    _readingClock.pause();
    // 暂停即落盘：退到后台被系统回收时不丢已停留的部分。
    _flushReadingDuration();
  }

  /// 把尚未写入的可见时长追加到统计（增量写入，不会重复累加）。
  void _flushReadingDuration() {
    // 与既有口径一致：只有书籍真正打开过的会话才计入，打开失败不计。
    if (!_opened) return;
    final seconds = _readingClock.takeIncrement();
    if (seconds <= 0) return;
    unawaited(
      _activity.logDuration(
        bookId: widget.bookId,
        durationSec: seconds,
        mode: ReaderActivityMode.reading,
        // 口径不变：一次阅读会话仍归到打开当天。
        at: _openedAt,
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    appRouteObserver.unsubscribe(this);
    // 退出阅读页只解绑高亮，不中断后台听书（M9.3）。
    _tts.unbindReader();
    final location = _location;
    if (_opened && location != null) {
      unawaited(
        _progress.save(
          widget.bookId,
          ReaderProgress(
            cfi: location.cfi,
            chapterIndex: location.chapterIndex,
            fraction: location.fraction,
            page: _recordPage(location),
            savedAt: DateTime.now(),
          ),
        ),
      );
      unawaited(
        _books.updateProgress(
          widget.bookId,
          chapterIndex: location.chapterIndex,
          fraction: location.fraction,
        ),
      );
    }
    // 结束计时并写入最后一段可见时长（被覆盖期间不计入）。
    _readingClock.stop();
    _flushReadingDuration();
    _bridge.dispose();
    super.dispose();
  }

  Future<void> _tryOpen() async {
    if (_opening || _opened || !_jsReady) return;
    final book = _books.byId(widget.bookId);
    if (book == null) {
      setState(() {
        _loading = false;
        _error = '书籍不存在或已删除';
      });
      return;
    }
    _opening = true;
    try {
      final bytes = _bytes ?? await readReaderBookFile(book.id, book.fileName);
      if (bytes == null || bytes.isEmpty) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = '书籍文件缺失，请回到书架重新导入';
        });
        return;
      }
      _bytes = bytes;
      // 换书时结束上一本的听书，避免高亮/断点串书。
      if (_tts.active && _tts.bookId != book.id) await _tts.stop();
      _tts.bindReader(
        book: book,
        port: _ttsPort,
        chapterTitleOf: (index) =>
            index < _toc.length ? _toc[index].label : '第${index + 1}章',
        chapterTitles: [for (final item in _toc) item.label],
      );
      if (!mounted) return;
      // 先读出上次进度再开始加载：WebView 首帧会先报 0 位置，
      // 若先加载再读进度，续读目标会被这次 0 位置覆盖。
      final saved = _progress.read(book.id);
      // 从播放条跳入：阅读位置对齐到正在朗读的章节，而不是旧阅读断点。
      final listening =
          _tts.active && _tts.bookId == book.id && _tts.chapterIndex >= 0;
      _resumeTarget = saved;
      _resumeSettled =
          listening || saved == null || saved.chapterIndex == 0;
      // PDF：读取页码侧车（缺失时退化为普通章节进度文案）。
      if (book.source == ReaderBookSource.localPdf) {
        final raw = await readReaderBookFile(book.id, PdfPageMap.fileName);
        if (raw != null) {
          _pdfPageMap = PdfPageMap.tryDecode(
            utf8.decode(raw, allowMalformed: true),
          );
        }
      }
      if (!mounted) return;
      final style = _buildStyle(context);
      _styleKey = _styleSignature(context);
      await _bridge.setStyle(style);
      await _bridge.openAt(
        chapterIndex: listening
            ? _tts.chapterIndex
            : (saved?.chapterIndex ?? book.lastChapterIndex),
        fraction: listening ? 0 : (saved?.fraction ?? book.lastFraction),
        cfi: listening ? null : saved?.cfi,
      );
      final ok = await _bridge.loadBook(
        fileName: book.fileName,
        bytes: bytes,
      );
      if (!ok) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = '书籍解析失败，文件可能已损坏';
        });
        return;
      }
      _opened = true;
      // 打开前的可见停留同样属于本次阅读（沿用原口径），这里只确保计时在跑。
      _syncReadingClock();
      // renderer 就绪后再注入一次样式（模式切换依赖 renderer 属性）。
      await _bridge.setStyle(style);
      // 再次绑定：若听书会话仍在后台，补挂高亮/续读下一章。
      _tts.bindReader(
        book: book,
        port: _ttsPort,
        chapterTitleOf: (index) =>
            index < _toc.length ? _toc[index].label : '第${index + 1}章',
        chapterTitles: [for (final item in _toc) item.label],
      );
      // 听书会话仍在后台：以朗读段落为锚点定位正文（未就绪时自动重试）。
      if (listening && mounted) {
        unawaited(_anchorToTtsParagraph());
      }
      _recordHistory(
        book,
        listening
            ? _tts.chapterIndex
            : (saved?.chapterIndex ?? book.lastChapterIndex),
      );
      // M9.4「进入书籍默认继续听书」：有听书断点才自动续读。
      if (!mounted) return;
      final ttsSettings = context.read<TtsSettingsStore>();
      if (ttsSettings.defaultListen &&
          book.ttsAllowed &&
          !_tts.active &&
          book.lastTtsParaIndex != null) {
        unawaited(
          _tts.start(
            chapterIndex: book.lastChapterIndex,
            paraIndex: book.lastTtsParaIndex,
          ),
        );
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = null;
      });
    } catch (e) {
      debugPrint('[reader] 打开书籍失败：$e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '打开书籍失败：$e';
      });
    } finally {
      _opening = false;
    }
  }

  /// 页码文案：翻页模式给出「当前页 / 总页数」，滚动模式无静态分页返回 null。
  ///
  /// - PDF：用页码侧车（[PdfPageMap]）把章内进度换算成原始 PDF 页码，总页数精确；
  /// - EPUB/TXT：当前页是渲染器实测的屏页，总页数按当前章「字数/屏」密度折算。
  String? _pageLabel() {
    if (_typography.value.flow != ReaderFlow.paged) return null;
    final location = _location;
    if (location == null) return null;
    final map = _pdfPageMap;
    if (map != null && map.pageCount > 0) {
      final chapter = map.chapterAt(location.chapterIndex);
      if (chapter == null) return null;
      final span = chapter.endPage - chapter.startPage + 1;
      if (span <= 0) return null;
      final offset =
          (location.fraction.clamp(0.0, 1.0) * span).floor().clamp(0, span - 1);
      return '${chapter.startPage + offset} / ${map.pageCount}';
    }
    final page = location.page;
    final total = location.pageCount;
    if (page == null || total == null || total <= 0) return null;
    return '$page / $total';
  }

  /// 页码快照（「最近记录」展示用）：PDF 走侧车换算原始页码，其余取渲染器页码。
  int? _recordPage(ReaderLocation location) {
    final map = _pdfPageMap;
    if (map != null && map.pageCount > 0) {
      final chapter = map.chapterAt(location.chapterIndex);
      if (chapter == null) return null;
      final span = chapter.endPage - chapter.startPage + 1;
      if (span <= 0) return null;
      final offset =
          (location.fraction.clamp(0.0, 1.0) * span).floor().clamp(0, span - 1);
      return chapter.startPage + offset;
    }
    return location.page;
  }

  /// 页脚页码：只在文案变化时推给 WebView，避免每次翻页多一次桥调用。
  void _syncPageLabel() {
    final label = _pageLabel() ?? '';
    if (label == _lastPageLabel) return;
    _lastPageLabel = label;
    unawaited(_bridge.setPageLabel(label));
  }

  void _recordHistory(ReaderBook book, int chapterIndex) {
    _activity.recordHistory(
      ReaderHistoryEntry(
        bookId: book.id,
        bookTitle: book.title,
        chapterTitle: book.lastReadAt == null
            ? '开始阅读'
            : '第${chapterIndex + 1}章',
        mode: ReaderActivityMode.reading,
        at: DateTime.now(),
      ),
    );
  }

  void _onBookMeta(ReaderBookMeta meta) {
    final book = _books.byId(widget.bookId);
    if (book == null) return;
    final next = book.copyWith(
      title: book.title.trim().isEmpty ? meta.title : book.title,
      author: book.author.isEmpty ? meta.author : book.author,
      chapterCount: meta.chapterCount > 0 ? meta.chapterCount : book.chapterCount,
    );
    if (next.title != book.title ||
        next.author != book.author ||
        next.chapterCount != book.chapterCount) {
      _books.upsert(next);
    }
  }

  void _onRelocated(ReaderLocation location) {
    if (!mounted) return;
    setState(() => _location = location);
    _syncPageLabel();
    // 续读目标未到达前（首帧通常报第 0 章），不写进度，避免覆盖断点。
    if (!_resumeSettled) {
      final target = _resumeTarget;
      if (target != null &&
          target.chapterIndex > 0 &&
          location.chapterIndex < target.chapterIndex) {
        return;
      }
      _resumeSettled = true;
    }
    final now = DateTime.now();
    if (now.difference(_lastSaveAt) < const Duration(seconds: 2)) return;
    _lastSaveAt = now;
    unawaited(
      _progress.save(
        widget.bookId,
        ReaderProgress(
          cfi: location.cfi,
          chapterIndex: location.chapterIndex,
          fraction: location.fraction,
          page: _recordPage(location),
          savedAt: now,
        ),
      ),
    );
    unawaited(
      _books.updateProgress(
        widget.bookId,
        chapterIndex: location.chapterIndex,
        fraction: location.fraction,
      ),
    );
    // 读写在同一次重定位上完成：页首段落直接来自本次 reloc 事件，
    // 不再另开定时器二次查询。朗读高亮自身滚动的 reloc 不回写，避免反向拖拽。
    //
    // 只在暂停时回写：播放中段落推进由 TTS 自己驱动，跨页/自动滚动产生的
    // reloc 携带的是「页首段」，回写会触发 repositionTo → _restartLoop，
    // 把朗读拉回本页第 1 段（读完页末段后回绕）。暂停后再翻页才更新断点。
    final paragraph = location.paragraphIndex;
    if (_tts.active &&
        _tts.paused &&
        _tts.bookId == widget.bookId &&
        !_tts.navigating &&
        !location.ttsScroll &&
        paragraph != null &&
        paragraph >= 0 &&
        location.chapterIndex == _tts.chapterIndex) {
      unawaited(_tts.repositionTo(location.chapterIndex, paragraph));
    }
  }

  /// 以朗读段落为唯一坐标锚定正文：章节未渲染时重试，直到高亮命中。
  Future<void> _anchorToTtsParagraph() async {
    for (var attempt = 0; attempt < 12; attempt++) {
      if (!mounted || !_tts.active || _tts.bookId != widget.bookId) return;
      if (await _bridge.highlightParagraph(_tts.paragraphIndex)) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<void> _toggleTts(ReaderBook book) async {
    if (!book.ttsAllowed) {
      _showTtsDisabled(book);
      return;
    }
    // 起播位置以「当前可见页」为准：跳页/跳章后点听书从当前页开始，而非旧书签。
    final chapter = _location?.chapterIndex ?? book.lastChapterIndex;
    if (_tts.active && _tts.bookId == book.id) {
      if (_tts.playing) {
        await _tts.pause();
        return;
      }
      // 暂停中：先把断点对齐到当前页，再从这里恢复。
      await _tts.alignToView(chapter);
      await _tts.resume();
      return;
    }
    if (_tts.active) await _tts.stop();
    _tts.bindReader(
      book: book,
      port: _ttsPort,
      chapterTitleOf: (index) =>
          index < _toc.length ? _toc[index].label : '第${index + 1}章',
    );
    // 起播段落取「页位置同一次测量」的段落索引（与阅读页显示一致），
    // 不再让 start 内部另调一次 visibleParagraph 形成第二个来源。
    final para = _location != null && _location!.chapterIndex == chapter
        ? _location!.paragraphIndex
        : null;
    await _tts.start(
      chapterIndex: chapter,
      paraIndex: para,
      fromBookmark: false,
    );
  }

  void _showTtsDisabled(ReaderBook book) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(book.ttsDisabledReason ?? '该书籍暂不支持朗读')),
      );
  }

  String _subtitleText(
    ReaderBook book,
    ReaderLocation? location,
    int percent,
  ) {
    final map = _pdfPageMap;
    if (book.source == ReaderBookSource.localPdf && map != null) {
      if (location == null) return book.progressText;
      return '${map.labelForChapter(location.chapterIndex)} · $percent%';
    }
    return location == null
        ? book.progressText
        : '第${location.chapterIndex + 1}/${book.chapterCount} 章 · $percent%';
  }

  /// PDF 页码跳转：页码 → 章节（每 20 页一章）→ 阅读器跳章。
  Future<void> _openPageJump(ReaderBook book) async {
    final map = _pdfPageMap;
    if (map == null || map.pageCount <= 0) return;
    final current = map.chapterAt(_location?.chapterIndex ?? 0);
    final controller = TextEditingController(
      text: '${current?.startPage ?? 1}',
    );
    final page = await showDialog<int>(
      context: context,
      builder: (dialogContext) {
        void submit() {
          final value = int.tryParse(controller.text.trim());
          if (value == null || value < 1 || value > map.pageCount) return;
          Navigator.of(dialogContext).pop(value);
        }

        return AlertDialog(
          title: const Text('跳转到页码'),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: '页码（1–${map.pageCount}）',
              helperText: 'PDF 按每 ${map.pagesPerChapter} 页一章重排，跳转定位到该页所在章',
            ),
            onSubmitted: (_) => submit(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(onPressed: submit, child: const Text('跳转')),
          ],
        );
      },
    );
    controller.dispose();
    if (page == null || !mounted) return;
    await _bridge.goToChapter(map.chapterForPage(page));
  }

  ReaderStylePayload _buildStyle(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ReaderStylePayload(
      typography: _typography.value,
      background: theme.scaffoldBackgroundColor,
      foreground: scheme.onSurface,
      muted: scheme.onSurfaceVariant,
      accent: scheme.primary,
      hairline: scheme.outline,
      isDark: theme.brightness == Brightness.dark,
    );
  }

  String _styleSignature(BuildContext context) {
    final theme = Theme.of(context);
    final t = _typography.value;
    return '${theme.scaffoldBackgroundColor.toARGB32()}|'
        '${theme.colorScheme.onSurface.toARGB32()}|'
        '${theme.colorScheme.primary.toARGB32()}|'
        '${t.fontSize}|${t.lineHeight}|${t.margin}|${t.weight}|${t.flow.storageValue}';
  }

  Future<void> _refreshWeb(ReaderBook book) async {
    final service = context.read<ReaderImportService>();
    setState(() => _refreshing = true);
    try {
      final outcome = await service.refreshWeb(book);
      final updated = outcome.book;
      if (!mounted) return;
      setState(() => _refreshing = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              '已重新抓取「${updated.title}」'
              '${outcome.notice == null ? '' : '；${outcome.notice}'}',
            ),
          ),
        );
      // 重新抓取后重载书籍：先回到未打开态再走一次 open 流程。
      _opened = false;
      _bytes = null;
      _toc.clear();
      setState(() => _loading = true);
      await _tryOpen();
    } on ReaderImportException catch (e) {
      if (!mounted) return;
      setState(() => _refreshing = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('重新抓取失败：${e.message}')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _refreshing = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('重新抓取失败：$e')));
    }
  }

  void _openToc() {
    showReaderTocSheet(
      context,
      items: List<ReaderTocItem>.from(_toc),
      currentIndex: _location?.chapterIndex ?? 0,
      onSelect: (item) {
        if (item.href.isEmpty) {
          _bridge.goToChapter(item.index);
        } else {
          _bridge.goToHref(item.href);
        }
      },
    );
  }

  void _openSettings() {
    showReaderSettingsSheet(context, store: _typography);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final book = context.watch<ReaderBookStore>().byId(widget.bookId);
    // 排版设置变化要触发重建，才能把新字号/行距推给 WebView。
    context.watch<ReaderTypographyStore>();
    final tts = context.watch<TtsSession>();

    if (kIsWeb) {
      return Scaffold(
        appBar: AppBar(title: Text(book?.title ?? '阅读')),
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(tokens.spaceLg),
            child: Text(
              '阅读功能请在 Android 端使用（Web 端仅调试预览）。',
              textAlign: TextAlign.center,
              style: tokens.bodyStyle,
            ),
          ),
        ),
      );
    }

    if (book == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('阅读')),
        body: const Center(child: Text('书籍不存在或已删除')),
      );
    }

    // 排版 / 皮肤变化时把新样式推给 WebView（渲染器就绪后）。
    final style = _buildStyle(context);
    final signature = _styleSignature(context);
    if (_opened && signature != _styleKey) {
      _styleKey = signature;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _bridge.setStyle(style);
        // 排版变化会重建分栏/页脚：先重设页码，新的页码等 JS 重算后回推。
        _syncPageLabel();
      });
    }

    final location = _location;
    final percent = book.chapterCount > 0
        ? ((location == null
                    ? book.overallProgress
                    : (location.chapterIndex + location.fraction) /
                        book.chapterCount) *
                100)
              .clamp(0, 100)
              .round()
        : book.progressPercent;

    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: InAppWebView(
                initialUrlRequest: URLRequest(
                  url: WebUri(
                    'https://$_assetDomain/assets/flutter_assets/assets/reader/index.html'
                    '?rv=2016',
                  ),
                ),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  transparentBackground: true,
                  supportZoom: false,
                  disableContextMenu: true,
                  // 本地 asset 不缓存：升级 APK 后必须拿到新版 index.html，
                  // 否则 WebView 会继续用旧桥协议（缺失段落索引字段）。
                  cacheEnabled: false,
                  cacheMode: CacheMode.LOAD_NO_CACHE,
                  webViewAssetLoader: WebViewAssetLoader(
                    domain: _assetDomain,
                    pathHandlers: [AssetsPathHandler(path: '/assets/')],
                  ),
                ),
                onWebViewCreated: _bridge.attach,
                onConsoleMessage: (controller, message) {
                  if (message.message.startsWith('READER_MSG')) {
                    debugPrint('[reader:console] ${message.message}');
                  }
                },
              ),
            ),
            if (_loading)
              Positioned.fill(
                child: ColoredBox(
                  color: scheme.surface,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(strokeWidth: 2.4),
                        SizedBox(height: tokens.spaceMd),
                        Text('正在打开《${book.title}》…', style: tokens.bodyStyle),
                      ],
                    ),
                  ),
                ),
              ),
            if (_error != null)
              Positioned.fill(
                child: ColoredBox(
                  color: scheme.surface,
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(tokens.spaceLg),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.error_outline_rounded, color: scheme.error),
                          SizedBox(height: tokens.spaceMd),
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: tokens.bodyStyle,
                          ),
                          SizedBox(height: tokens.spaceMd),
                          OutlinedButton(
                            onPressed: () => Navigator.of(context).maybePop(),
                            child: const Text('返回书架'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            // 顶栏（点击正文中间区域切换显隐）
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AnimatedSlide(
                offset: _toolbarVisible ? Offset.zero : const Offset(0, -1),
                duration: const Duration(milliseconds: 180),
                child: AnimatedOpacity(
                  opacity: _toolbarVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: IgnorePointer(
                    ignoring: !_toolbarVisible,
                    child: Container(
                      color: scheme.surface,
                      padding: EdgeInsets.fromLTRB(
                        tokens.spaceXs,
                        tokens.spaceXs,
                        tokens.spaceSm,
                        tokens.spaceXs,
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: '返回',
                            onPressed: () => Navigator.of(context).maybePop(),
                            icon: const Icon(Icons.arrow_back_ios_new_rounded),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  book.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: tokens.sectionStyle,
                                ),
                                Text(
                                  _subtitleText(book, location, percent),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: tokens.captionStyle,
                                ),
                              ],
                            ),
                          ),
                          if (book.source == ReaderBookSource.webArticle)
                            IconButton(
                              tooltip: '重新抓取',
                              onPressed:
                                  _refreshing ? null : () => _refreshWeb(book),
                              icon: _refreshing
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.refresh_rounded),
                            ),
                          if (book.source == ReaderBookSource.localPdf &&
                              _pdfPageMap != null)
                            IconButton(
                              tooltip: '跳转页码',
                              onPressed: () => _openPageJump(book),
                              icon: const Icon(Icons.numbers_rounded),
                            ),
                          IconButton(
                            tooltip: book.ttsAllowed
                                ? ((_tts.active && _tts.bookId == book.id)
                                      ? '听书控制'
                                      : '听书')
                                : '该 PDF 已关闭朗读',
                            onPressed: book.ttsAllowed
                                ? () => _toggleTts(book)
                                : null,
                            icon: Icon(
                              (_tts.active && _tts.bookId == book.id)
                                  ? Icons.headphones_rounded
                                  : Icons.headphones_outlined,
                            ),
                          ),
                          IconButton(
                            tooltip: '目录',
                            onPressed: _openToc,
                            icon: const Icon(Icons.format_list_bulleted_rounded),
                          ),
                          IconButton(
                            tooltip: '排版',
                            onPressed: _openSettings,
                            icon: const Icon(Icons.tune_rounded),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // B 级提示：文字抽取不可靠的 PDF 关闭朗读（M10.3）。
            if (!book.ttsAllowed && _toolbarVisible)
              Positioned(
                top: 72,
                left: tokens.spaceSm,
                right: tokens.spaceSm,
                child: Material(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.headset_off_rounded,
                          size: 18,
                          color: scheme.onErrorContainer,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '该 PDF 文字抽取不可靠，已关闭朗读（仍可阅读）',
                            style: tokens.captionStyle.copyWith(
                              color: scheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // 听书控制条（退出页面后仍可在通知栏控制）
            if (tts.active && tts.bookId == book.id)
              Positioned(
                left: tokens.spaceSm,
                right: tokens.spaceSm,
                bottom: _toolbarVisible ? 66 : tokens.spaceSm,
                child: ReaderTtsBar(session: tts),
              ),
            // 底栏：进度 + 翻页
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: AnimatedSlide(
                offset: _toolbarVisible ? Offset.zero : const Offset(0, 1),
                duration: const Duration(milliseconds: 180),
                child: AnimatedOpacity(
                  opacity: _toolbarVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: IgnorePointer(
                    ignoring: !_toolbarVisible,
                    child: Container(
                      color: scheme.surface,
                      padding: EdgeInsets.fromLTRB(
                        tokens.spaceMd,
                        tokens.spaceXs,
                        tokens.spaceSm,
                        tokens.spaceXs,
                      ),
                      child: Row(
                        children: [
                          Text(
                            _typography.value.flow.label,
                            style: tokens.captionStyle,
                          ),
                          const Spacer(),
                          // 页码：翻页模式「当前页 / 总页数」（与常驻页脚同一口径）；
                          // 滚动模式无静态分页，退化为全书进度百分比。
                          if (_typography.value.flow == ReaderFlow.scrolled)
                            Text(
                              '全书 $percent%',
                              style: tokens.captionStyle.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            )
                          else if (_pageLabel() != null)
                            Text(
                              _pageLabel()!,
                              style: tokens.captionStyle.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          SizedBox(width: tokens.spaceMd),
                          TextButton.icon(
                            onPressed: () => _bridge.prev(),
                            icon: const Icon(Icons.chevron_left_rounded),
                            label: const Text('上一页'),
                          ),
                          SizedBox(width: tokens.spaceXs),
                          TextButton.icon(
                            onPressed: () => _bridge.next(),
                            icon: const Icon(Icons.chevron_right_rounded),
                            label: const Text('下一页'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 阅读页 → TTS 的端口实现：所有 WebView 交互都经由 [ReaderBridge]。
class _BridgeTtsPort implements TtsReaderPort {
  _BridgeTtsPort(this._bridge);

  final ReaderBridge _bridge;

  @override
  Future<int> currentChapter() => _bridge.currentChapter();

  @override
  Future<List<String>> paragraphsOf(int chapterIndex) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (await _bridge.isChapterReady(chapterIndex)) {
        // renderer 完成分栏后再读 DOM，避免拿到上一章的节点。
        await Future<void>.delayed(const Duration(milliseconds: 240));
        return _bridge.extractParagraphs();
      }
      await _bridge.goToChapter(chapterIndex);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return _bridge.extractParagraphs();
  }

  @override
  Future<void> highlight(int paragraphIndex, {bool scroll = true}) async {
    if (scroll) {
      await _bridge.highlightParagraph(paragraphIndex);
    } else {
      await _bridge.markParagraph(paragraphIndex);
    }
  }

  @override
  Future<void> clearHighlight() => _bridge.clearHighlight();

  @override
  Future<int> visibleParagraph() => _bridge.visibleParagraphIndex();
}
