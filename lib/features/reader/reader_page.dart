import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

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

class _ReaderPageState extends State<ReaderPage> {
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
  Timer? _ttsSyncTimer;

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

  @override
  void initState() {
    super.initState();
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
  void dispose() {
    _ttsSyncTimer?.cancel();
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
    final seconds = DateTime.now().difference(_openedAt).inSeconds;
    if (_opened && seconds >= 5) {
      unawaited(
        _activity.logDuration(
          bookId: widget.bookId,
          durationSec: seconds,
          mode: ReaderActivityMode.reading,
          at: _openedAt,
        ),
      );
    }
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
      );
      if (!mounted) return;
      // 先读出上次进度再开始加载：WebView 首帧会先报 0 位置，
      // 若先加载再读进度，续读目标会被这次 0 位置覆盖。
      final saved = _progress.read(book.id);
      _resumeTarget = saved;
      _resumeSettled = saved == null || saved.chapterIndex == 0;
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
        chapterIndex: saved?.chapterIndex ?? book.lastChapterIndex,
        fraction: saved?.fraction ?? book.lastFraction,
        cfi: saved?.cfi,
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
      // renderer 就绪后再注入一次样式（模式切换依赖 renderer 属性）。
      await _bridge.setStyle(style);
      // 再次绑定：若听书会话仍在后台，补挂高亮/续读下一章。
      _tts.bindReader(
        book: book,
        port: _ttsPort,
        chapterTitleOf: (index) =>
            index < _toc.length ? _toc[index].label : '第${index + 1}章',
      );
      _recordHistory(book, saved?.chapterIndex ?? book.lastChapterIndex);
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
    // 手动翻页/跳章时让听书同步到当前可见段落（TTS 自身滚动不会触发重定位）。
    if (_tts.active &&
        _tts.bookId == widget.bookId &&
        _tts.playing &&
        !_tts.navigating) {
      _scheduleTtsSync(location);
    }
  }

  void _scheduleTtsSync(ReaderLocation location) {
    _ttsSyncTimer?.cancel();
    _ttsSyncTimer = Timer(const Duration(milliseconds: 600), () async {
      if (!mounted || !_tts.active || !_tts.playing || _tts.navigating) return;
      final paragraph = await _bridge.visibleParagraphIndex();
      if (!mounted || !_tts.active || !_tts.playing || _tts.navigating) return;
      await _tts.repositionTo(location.chapterIndex, paragraph);
    });
  }

  Future<void> _toggleTts(ReaderBook book) async {
    if (!book.ttsAllowed) {
      _showTtsDisabled(book);
      return;
    }
    final active = _tts.active && _tts.bookId == book.id;
    if (active) {
      await _tts.toggle();
      return;
    }
    if (_tts.active) await _tts.stop();
    _tts.bindReader(
      book: book,
      port: _ttsPort,
      chapterTitleOf: (index) =>
          index < _toc.length ? _toc[index].label : '第${index + 1}章',
    );
    final chapter = book.lastTtsParaIndex != null
        ? book.lastChapterIndex
        : (_location?.chapterIndex ?? book.lastChapterIndex);
    await _tts.start(
      chapterIndex: chapter,
      paraIndex: book.lastTtsParaIndex,
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
                    'https://$_assetDomain/assets/flutter_assets/assets/reader/index.html',
                  ),
                ),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  transparentBackground: true,
                  supportZoom: false,
                  disableContextMenu: true,
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
  Future<void> highlight(int paragraphIndex) =>
      _bridge.highlightParagraph(paragraphIndex);

  @override
  Future<void> clearHighlight() => _bridge.clearHighlight();

  @override
  Future<int> visibleParagraph() => _bridge.visibleParagraphIndex();
}
