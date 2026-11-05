import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/dev_flags.dart';
import '../../app/theme/app_tokens.dart';
import '../../app/widgets/common.dart';
import '../../core/api/album_source.dart';
import '../../core/data/dao_demo.dart';
import '../../core/data/daos.dart';
import '../../core/data/local_database.dart';
import '../../core/domain/album.dart';
import '../../core/domain/reader_book.dart';
import '../../core/services/player/player_service.dart';
import '../../core/services/reader/book_store.dart';
import '../../core/services/reader/pdf_quality.dart';
import '../../core/services/reader/reader_import_service.dart';
import '../../core/services/shelf_controller.dart';
import '../discover/album_card.dart';
import '../reader/web_import_sheet.dart';
import 'shelf_tab.dart';

/// Tab 2 书架（PRD §5.3，M4 接入）。
///
/// 结构：
/// - 在听置顶区：30 天内有收听且未听完的专辑，卡片 + 进度条，点击续播；
/// - 收藏列表：封面 / 章节进度（已听 x/y）/ 最后收听时间；
/// - 排序：最近收听 / 收藏时间 / 标题；
/// - 长按多选删除、左滑删除（带撤销）；
/// - 空态引导跳发现页。
///
/// 数据来自 [ShelfController.buildViews]（shelf × album × play_history 联合查询），
/// 每次 build 同步重读，保证切回页面 / 收藏状态变化后读到最新进度。
class ShelfPage extends StatefulWidget {
  const ShelfPage({super.key});

  @override
  State<ShelfPage> createState() => _ShelfPageState();
}

enum _SortMode { recent, collected, title }

extension _SortModeX on _SortMode {
  String get label => switch (this) {
    _SortMode.recent => '最近收听',
    _SortMode.collected => '收藏时间',
    _SortMode.title => '标题',
  };
}

class _ShelfPageState extends State<ShelfPage> {
  _SortMode _sort = _SortMode.recent;

  // ── 分栏（M10 追加）：本地导入的书 / 在线收藏 ──
  ShelfSection _section = ShelfSection.local;
  final ScrollController _scroll = ScrollController();
  final Map<ShelfSection, double> _scrollOffsets = {
    ShelfSection.local: 0,
    ShelfSection.favorite: 0,
  };

  // 多选删除态
  bool _selecting = false;
  final Set<String> _selected = {};

  // ── 本地书（M9.1）：独立排序与多选，与上面的 B 站收藏互不感知 ──
  ReaderSortMode _localSort = ReaderSortMode.recent;
  bool _localSelecting = false;
  final Set<String> _localSelected = {};

  // 收藏分栏里的网页文章（非本地来源）；章节标题行已移除，固定按最近更新
  final ReaderSortMode _favBookSort = ReaderSortMode.recent;
  final Set<String> _favBookSelected = {};
  bool _importing = false;

  // M1 数据层自检（保留：M1 准出证据，且 widget_test 依赖其文案）
  DaoDemoReport? _report;
  bool _running = false;
  Map<String, int> _counts = const {};

  @override
  void initState() {
    super.initState();
    // 旧版本备份/空壳收藏：进书架后静默补抓专辑元数据（最多 5 张，失败不打扰，
    // 点击卡片时再给出「重试」入口）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _backfillAlbumMeta());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 切换分栏：记住当前滚动位置，切回时恢复（列表按需重建，不重复加载）。
  void _switchSection(ShelfSection next) {
    if (next == _section) return;
    _scrollOffsets[_section] = _scroll.hasClients ? _scroll.offset : 0;
    setState(() {
      _section = next;
      _selecting = false;
      _selected.clear();
      _favBookSelected.clear();
      _localSelecting = false;
      _localSelected.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      _scroll.jumpTo(_scrollOffsets[next]!.clamp(0, max));
    });
  }

  Future<void> _runDemo() async {
    final daos = context.read<Daos>();
    setState(() => _running = true);
    final report = await runDaoDemo(daos);
    final counts = await daos.db.counts();
    if (!mounted) return;
    setState(() {
      _report = report;
      _counts = counts;
      _running = false;
    });
  }

  // ───────────────────────────────────────────────────────── 续播
  Future<void> _resume(String albumId) async {
    final daos = context.read<Daos>();
    var album = daos.albums.get(albumId);
    if (album == null) {
      // 旧版备份只还原了 album_id：先按 id 现拉元数据/曲目入库再续播。
      final messenger = ScaffoldMessenger.of(context);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('正在获取专辑信息…'),
          duration: Duration(seconds: 2),
        ));
      album = await _fetchAlbumMeta(albumId);
      messenger.hideCurrentSnackBar();
      if (album == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: const Text('本地缺少这本专辑的信息（旧版备份未包含）。可重试补抓，或到发现页重新搜索后收藏。'),
            action: SnackBarAction(
              label: '重试',
              onPressed: () => _resume(albumId),
            ),
            duration: const Duration(seconds: 8),
          ));
        return;
      }
      if (mounted) setState(() {});
    }
    if (!mounted) return;
    final player = context.read<PlayerService>();
    // 播放入口统一语义：只有详情页「播放全部」才跳播放页；这里就地
    // 开播并显示播放条（点击播放条才进播放页），不随装载时序跳转
    // （原先 await 装载后 push，会出现播放条先弹出再跳页的突兀过渡）。
    unawaited(player.playAlbum(album)); // 不指定章节 → 自动续播到最后听的章节
  }

  /// 缺专辑信息的收藏：按 id 现拉元数据 + 曲目并合并入库。
  /// 离线/音源失效时返回 null（由 [_resume] 给出明确提示与重试）。
  Future<Album?> _fetchAlbumMeta(String albumId) async {
    final source = context.read<AlbumSource>();
    final daos = context.read<Daos>();
    final isSeries =
        albumId.startsWith('season:') || albumId.startsWith('series:');
    try {
      final bundle = await source.load(
        id: albumId,
        sourceType: isSeries ? SourceType.series : SourceType.multiPart,
      );
      await daos.albums.upsert(bundle.album);
      if (bundle.chapters.isNotEmpty) {
        await daos.chapters.upsertAll(bundle.chapters);
      }
      return bundle.album;
    } catch (_) {
      return null;
    }
  }

  Future<void> _backfillAlbumMeta() async {
    if (!mounted) return;
    final shelf = context.read<ShelfController>();
    final missing = [
      for (final v in shelf.buildViews())
        if (v.album == null) v.item.albumId,
    ].take(5).toList();
    if (missing.isEmpty) return;
    var changed = false;
    for (final id in missing) {
      if (!mounted) return;
      if (await _fetchAlbumMeta(id) != null) changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  // ───────────────────────────────────────────────────── 本地书（M9.1）
  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _cancelSelectionAction() => TextButton(
    onPressed: () => setState(() {
      _selecting = false;
      _selected.clear();
      _favBookSelected.clear();
      _localSelecting = false;
      _localSelected.clear();
    }),
    child: const Text('取消'),
  );

  Widget _readerSortAction() => PopupMenuButton<ReaderSortMode>(
    tooltip: '本地书排序',
    icon: const Icon(Icons.sort_rounded),
    onSelected: (m) => setState(() => _localSort = m),
    itemBuilder: (_) => [
      for (final m in ReaderSortMode.values)
        PopupMenuItem(
          value: m,
          child: Row(
            children: [
              if (_localSort == m)
                Icon(
                  Icons.check_rounded,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                )
              else
                const SizedBox(width: 18),
              const SizedBox(width: 8),
              Text(m.label),
            ],
          ),
        ),
    ],
  );

  Widget _albumSortAction() => PopupMenuButton<_SortMode>(
    tooltip: '排序',
    icon: const Icon(Icons.sort_rounded),
    onSelected: (m) => setState(() => _sort = m),
    itemBuilder: (_) => [
      for (final m in _SortMode.values)
        PopupMenuItem(
          value: m,
          child: Row(
            children: [
              if (_sort == m)
                Icon(
                  Icons.check_rounded,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                )
              else
                const SizedBox(width: 18),
              const SizedBox(width: 8),
              Text(m.label),
            ],
          ),
        ),
    ],
  );

  Future<void> _deleteSelectedLocal() =>
      _deleteSelectedBooks(_localSelected, title: '删除本地书');

  /// 收藏分栏的多选删除：专辑与网页文章分开清理，确认后统一执行。
  Future<void> _deleteFavoriteSelected() async {
    final albumIds = [..._selected];
    final bookIds = [..._favBookSelected];
    if (albumIds.isEmpty && bookIds.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('从收藏移除'),
        content: Text(
          '将移除 ${albumIds.length + bookIds.length} 项'
          '${bookIds.isEmpty ? '。' : '，其中 ${bookIds.length} 篇文章会同时删除本地文件。'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    if (albumIds.isNotEmpty) {
      await context.read<ShelfController>().removeAll(albumIds);
    }
    if (!mounted) return;
    if (bookIds.isNotEmpty) {
      final store = context.read<ReaderBookStore>();
      final service = context.read<ReaderImportService>();
      for (final id in bookIds) {
        final book = store.byId(id);
        if (book == null) continue;
        await store.remove(id);
        await service.purge(book);
      }
    }
    if (!mounted) return;
    setState(() {
      _selecting = false;
      _selected.clear();
      _favBookSelected.clear();
    });
    _toast('已移除 ${albumIds.length + bookIds.length} 项');
  }

  Future<void> _showImportMenu() async {
    final action = await showModalBottomSheet<_ImportAction>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('导入本地文件'),
              subtitle: const Text('TXT / EPUB / PDF（仅文字层）'),
              onTap: () =>
                  Navigator.of(sheetContext).pop(_ImportAction.localFile),
            ),
            ListTile(
              leading: const Icon(Icons.link_rounded),
              title: const Text('导入网页链接'),
              subtitle: const Text('公众号 / 新闻 / 博客文章'),
              onTap: () => Navigator.of(sheetContext).pop(_ImportAction.web),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _ImportAction.localFile:
        await _importLocalFile();
      case _ImportAction.web:
        await _importWebLink();
    }
  }

  Future<void> _importLocalFile() async {
    // 原生端不把整份文件读进内存（PDF 可能是 100MB 级），走路径读取；
    // Web 端 file_picker 只有 bytes，仍保留 withData。
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['txt', 'epub', 'pdf'],
      withData: kIsWeb,
    );
    final file = result?.files.isEmpty == false ? result!.files.first : null;
    if (file == null) return;
    if (!mounted) return;

    final extension = (file.extension ?? '').toLowerCase();
    if (extension == 'pdf') {
      await _importPdf(file);
      return;
    }
    if (extension != 'txt' && extension != 'epub') {
      if (mounted) _toast('仅支持 TXT / EPUB / PDF 文件');
      return;
    }

    Uint8List? bytes = file.bytes;
    if (bytes == null) {
      try {
        bytes = await file.xFile.readAsBytes();
      } catch (_) {
        if (mounted) _toast('无法读取文件内容，请重试');
        return;
      }
    }
    if (bytes.isEmpty) {
      if (mounted) _toast('文件为空');
      return;
    }

    if (!mounted) return;
    final service = context.read<ReaderImportService>();
    setState(() => _importing = true);
    try {
      final ReaderBook book;
      if (extension == 'txt') {
        book = await service.importTxt(bytes: bytes, fileName: file.name);
      } else {
        book = await service.importEpub(bytes: bytes, fileName: file.name);
      }
      if (!mounted) return;
      _toast('已导入「${book.title}」· ${book.chapterCount} 章');
    } on ReaderImportException catch (e) {
      if (!mounted) return;
      _toast('导入失败：${e.message}');
    } catch (e) {
      if (!mounted) return;
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// PDF 导入：进度/取消 → 质量提示 → 落盘（M10.1）。
  Future<void> _importPdf(PlatformFile file) async {
    final path = file.path;
    if (kIsWeb || path == null) {
      await _showPdfNotice(
        title: '当前平台不支持 PDF 导入',
        message: 'PDF 文字层解析依赖本机原生库，请在 Android 客户端导入。',
      );
      return;
    }
    if (file.size > PdfLimits.maxFileBytes) {
      await _showPdfNotice(
        title: 'PDF 过大',
        message: '当前上限 100 MB，该文件约 '
            '${(file.size / 1024 / 1024).toStringAsFixed(1)} MB，暂不支持导入。',
      );
      return;
    }

    final service = context.read<ReaderImportService>();
    var cancelled = false;
    var progressOpen = true;
    final progress = ValueNotifier<double>(0);
    final navigator = Navigator.of(context, rootNavigator: true);
    // 进度弹窗不阻塞交互层之外的页面；取消由回调传入解析器。
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('正在解析 PDF'),
          content: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (_, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: value),
                const SizedBox(height: 12),
                Text('已处理 ${(value * 100).round()}%'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                cancelled = true;
                if (progressOpen) {
                  navigator.pop();
                  progressOpen = false;
                }
              },
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );

    void closeProgress() {
      if (!progressOpen) return;
      progressOpen = false;
      navigator.pop();
    }

    setState(() => _importing = true);
    try {
      final data = await service.inspectPdf(
        path: path,
        fileName: file.name,
        onProgress: (value) {
          if (!cancelled) progress.value = value;
        },
        isCancelled: () => cancelled,
      );
      if (!mounted) return;
      closeProgress();
      if (!cancelled && data.inspection.quality != PdfReadQuality.good) {
        final proceed = await _confirmPdfImport(data.inspection);
        if (!mounted || !proceed) return;
      }
      if (cancelled) return;
      final book = await service.importPdf(data: data, fileName: file.name);
      if (!mounted) return;
      _toast(
        '已导入「${book.title}」· ${book.pdfPageCount} 页'
        '${book.pdfQuality == PdfReadQuality.mixed ? '（含无文字页）' : ''}',
      );
    } on ReaderImportException catch (e) {
      if (!mounted) return;
      closeProgress();
      if (e.kind == ReaderImportError.cancelled) {
        _toast('已取消导入');
      } else if (e.kind == ReaderImportError.pdfScanned) {
        await _showPdfNotice(
          title: '暂不支持扫描件 PDF',
          message: '该文件没有可抽取的文字层（每页都是图片）。\n'
              '当前版本不做 OCR，无法重排阅读或朗读；'
              '请使用带文字层的 PDF，或先用其他工具 OCR 后再导入。',
        );
      } else {
        _toast('导入失败：${e.message}');
      }
    } catch (e) {
      if (!mounted) return;
      closeProgress();
      _toast('导入失败：$e');
    } finally {
      progress.dispose();
      if (mounted) setState(() => _importing = false);
    }
  }

  /// 混合版/低质量确认；返回 true 表示继续导入。
  Future<bool> _confirmPdfImport(PdfInspection inspection) async {
    final isLowQuality = inspection.quality == PdfReadQuality.unreliable;
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isLowQuality ? '文字抽取不可靠' : '检测到混合版 PDF'),
        content: Text(inspection.warningText ?? ''),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(isLowQuality ? '仅阅读并导入' : '继续导入'),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _showPdfNotice({
    required String title,
    required String message,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _importWebLink() async {
    final service = context.read<ReaderImportService>();
    final outcome = await showWebImportSheet(context, service: service);
    if (!mounted || outcome == null) return;
    final book = outcome.book;
    final notice = outcome.notice;
    _toast(
      '已导入「${book.title}」· ${book.chapterCount} 章'
      '${notice == null ? '' : '；$notice'}',
    );
  }

  /// 打开本地书；文件缺失时给出重导/重抓引导（M9.4：还原备份后常见）。
  Future<void> _openLocalBook(ReaderBook book) async {
    final bookStore = context.read<ReaderBookStore>();
    if (!bookStore.isMissing(book.id)) {
      context.push('/reader/${book.id}');
      return;
    }
    final service = context.read<ReaderImportService>();
    final action = await showDialog<_MissingAction>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('书籍文件缺失'),
        content: Text(
          '「${book.title}」的书籍文件不在本机（还原备份或清理缓存后可能出现）。'
          '可重新导入原文件${book.originUrl != null ? '，或将网页文章重新抓取' : ''}。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          if (book.originUrl != null)
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_MissingAction.refetch),
              child: const Text('重新抓取'),
            ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_MissingAction.reimport),
            child: const Text('重新导入文件'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _MissingAction.reimport:
        await _importLocalFile();
      case _MissingAction.refetch:
        setState(() => _importing = true);
        try {
          final outcome = await service.refreshWeb(book);
          final updated = outcome.book;
          if (!mounted) return;
          _toast(
            '已重新抓取「${updated.title}」'
            '${outcome.notice == null ? '' : '；${outcome.notice}'}',
          );
          context.push('/reader/${updated.id}');
        } on ReaderImportException catch (e) {
          if (mounted) _toast('重新抓取失败：${e.message}');
        } catch (e) {
          if (mounted) _toast('重新抓取失败：$e');
        } finally {
          if (mounted) setState(() => _importing = false);
        }
    }
  }

  /// 删除选中的本地书；[selection] 决定作用范围（本地书 / 收藏文章）。
  Future<void> _deleteSelectedBooks(
    Set<String> selection, {
    required String title,
  }) async {
    if (selection.isEmpty) return;
    final ids = [...selection];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text('将删除 ${ids.length} 本书籍文件、阅读进度与阅读记录，且不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final store = context.read<ReaderBookStore>();
    final service = context.read<ReaderImportService>();
    for (final id in ids) {
      final book = store.byId(id);
      if (book != null) await service.purge(book);
    }
    if (!mounted) return;
    setState(() {
      if (identical(selection, _localSelected)) {
        _localSelecting = false;
      }
      selection.clear();
    });
    _toast('已删除 ${ids.length} 本');
  }

  // ───────────────────────────────────────────────────────── 排序
  List<ShelfView> _sorted(List<ShelfView> views) {
    final list = [...views];
    switch (_sort) {
      case _SortMode.recent:
        list.sort((a, b) => b.lastPlayedAt.compareTo(a.lastPlayedAt));
      case _SortMode.collected:
        list.sort((a, b) => b.collectedAt.compareTo(a.collectedAt));
      case _SortMode.title:
        list.sort((a, b) => a.title.compareTo(b.title));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    // watch：收藏状态变化（详情/播放页 toggle）实时反映到书架
    final shelf = context.watch<ShelfController>();
    final db = context.read<LocalDatabase>();

    final views = shelf.buildViews();
    final listening = views.where((v) => v.inListening).toList()
      ..sort((a, b) => b.lastPlayedAt.compareTo(a.lastPlayedAt));
    final sorted = _sorted(views);

    // 本地书（M9.1）：独立数据源，与上面的 B 站收藏互不感知。
    final bookStore = context.watch<ReaderBookStore>();
    final localActive = _section == ShelfSection.local;
    final localBooks = bookStore
        .sorted(_localSort)
        .where((book) => shelfSectionOf(book.source) == ShelfSection.local)
        .toList();
    final favoriteBooks = bookStore
        .sorted(_favBookSort)
        .where((book) => shelfSectionOf(book.source) == ShelfSection.favorite)
        .toList();

    return SafeArea(
      bottom: false,
      child: ListView(
        controller: _scroll,
        padding: EdgeInsets.only(bottom: tokens.spaceLg),
        children: [
          PageHeader(
            title: '书架',
            actions: localActive
                ? (_localSelecting
                      ? [
                          _cancelSelectionAction(),
                        ]
                      : [
                          IconButton(
                            tooltip: '导入本地书',
                            onPressed: _importing ? null : _showImportMenu,
                            icon: _importing
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.library_add_outlined),
                          ),
                          IconButton(
                            tooltip: '选择删除',
                            onPressed: () => setState(() {
                              _localSelecting = true;
                              _localSelected.clear();
                            }),
                            icon: const Icon(Icons.checklist_rounded),
                          ),
                          _readerSortAction(),
                        ])
                : (_selecting
                      ? [_cancelSelectionAction()]
                      : [
                          IconButton(
                            tooltip: '选择删除',
                            onPressed: () => setState(() {
                              _selecting = true;
                              _selected.clear();
                              _favBookSelected.clear();
                            }),
                            icon: const Icon(Icons.checklist_rounded),
                          ),
                          _albumSortAction(),
                        ]),
          ),

          // ── 分栏切换：本地 / 收藏 ─────────────────────────────────
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spaceMd,
              0,
              tokens.spaceMd,
              tokens.spaceSm,
            ),
            child: SegmentedButton<ShelfSection>(
              segments: [
                for (final section in ShelfSection.values)
                  ButtonSegment(value: section, label: Text(section.label)),
              ],
              selected: {_section},
              showSelectedIcon: false,
              onSelectionChanged: (value) => _switchSection(value.first),
            ),
          ),

          // ── 多选删除操作条 ───────────────────────────────────────
          if (_selecting)
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spaceMd,
                0,
                tokens.spaceMd,
                tokens.spaceSm,
              ),
              child: KeleCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Text(
                      '已选 ${_selected.length + _favBookSelected.length} 项',
                      style: tokens.bodyStyle,
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => setState(() {
                        final allSelected =
                            _selected.length == views.length &&
                            _favBookSelected.length == favoriteBooks.length;
                        if (allSelected) {
                          _selected.clear();
                          _favBookSelected.clear();
                        } else {
                          _selected
                            ..clear()
                            ..addAll(views.map((v) => v.item.albumId));
                          _favBookSelected
                            ..clear()
                            ..addAll(favoriteBooks.map((b) => b.id));
                        }
                      }),
                      child: Text(
                        _selected.length == views.length &&
                                _favBookSelected.length == favoriteBooks.length
                            ? '取消全选'
                            : '全选',
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed:
                          _selected.isEmpty && _favBookSelected.isEmpty
                          ? null
                          : _deleteFavoriteSelected,
                      child: const Text('删除'),
                    ),
                  ],
                ),
              ),
            ),

          // ── 在听置顶区（仅收藏分栏） ──────────────────────────────
          if (!localActive && listening.isNotEmpty) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spaceMd,
                tokens.spaceLg,
                tokens.spaceMd,
                0,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.graphic_eq_rounded,
                    color: scheme.primary,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text('在听', style: tokens.sectionStyle),
                  const SizedBox(width: 8),
                  StageTag('续播', tone: StageTone.accent),
                ],
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 150,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: tokens.spaceMd),
                itemCount: listening.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, i) =>
                    _ListeningCard(view: listening[i], onTap: _resume),
              ),
            ),
          ],

          // ── 本地书（M9.1） ─────────────────────────────────────────
          if (localActive) ...[
            if (_localSelecting)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  tokens.spaceMd,
                  tokens.spaceSm,
                  tokens.spaceMd,
                  0,
                ),
                child: KeleCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Text(
                        '已选 ${_localSelected.length} 本',
                        style: tokens.bodyStyle,
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setState(() {
                          if (_localSelected.length == localBooks.length) {
                            _localSelected.clear();
                          } else {
                            _localSelected
                              ..clear()
                              ..addAll(localBooks.map((b) => b.id));
                          }
                        }),
                        child: Text(
                          _localSelected.length == localBooks.length
                              ? '取消全选'
                              : '全选',
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonal(
                        onPressed: _localSelected.isEmpty
                            ? null
                            : _deleteSelectedLocal,
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                ),
              ),
            if (localBooks.isNotEmpty)
              _ShelfGrid(
                itemCount: localBooks.length,
                itemBuilder: (context, index) {
                  final book = localBooks[index];
                  return _LocalBookCard(
                    book: book,
                    missing: bookStore.isMissing(book.id),
                    selecting: _localSelecting,
                    selected: _localSelected.contains(book.id),
                    onTap: () {
                      if (_localSelecting) {
                        setState(() {
                          if (_localSelected.contains(book.id)) {
                            _localSelected.remove(book.id);
                          } else {
                            _localSelected.add(book.id);
                          }
                        });
                      } else {
                        _openLocalBook(book);
                      }
                    },
                    onLongPress: () => setState(() {
                      _localSelecting = true;
                      _localSelected.add(book.id);
                    }),
                  );
                },
              ),
            if (localBooks.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: tokens.spaceMd),
                child: _SectionEmptyState(
                  spec: shelfEmptySpecOf(ShelfSection.local),
                  icon: Icons.library_books_outlined,
                  onAction: _showImportMenu,
                ),
              ),
          ],

          // ── 收藏的文章（网页文章等非本地来源；当前归类规则下为空） ──
          if (!localActive && favoriteBooks.isNotEmpty)
            _ShelfGrid(
              itemCount: favoriteBooks.length,
              itemBuilder: (context, index) {
                final book = favoriteBooks[index];
                return _LocalBookCard(
                  book: book,
                  missing: bookStore.isMissing(book.id),
                  selecting: _selecting,
                  selected: _favBookSelected.contains(book.id),
                  onTap: () {
                    if (_selecting) {
                      setState(() {
                        if (_favBookSelected.contains(book.id)) {
                          _favBookSelected.remove(book.id);
                        } else {
                          _favBookSelected.add(book.id);
                        }
                      });
                    } else {
                      _openLocalBook(book);
                    }
                  },
                  onLongPress: () => setState(() {
                    _selecting = true;
                    _favBookSelected.add(book.id);
                  }),
                );
              },
            ),

          // ── 收藏列表（仅收藏分栏） ───────────────────────────────
          if (!localActive) ...[
            if (sorted.isEmpty && favoriteBooks.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: tokens.spaceMd),
                child: _SectionEmptyState(
                  spec: shelfEmptySpecOf(ShelfSection.favorite),
                  icon: Icons.favorite_border_rounded,
                  onAction: () => context.go('/discover'),
                ),
              )
            else if (sorted.isNotEmpty)
              _ShelfGrid(
                itemCount: sorted.length,
                itemBuilder: (context, index) {
                  final v = sorted[index];
                  return _AlbumShelfCard(
                    view: v,
                    selecting: _selecting,
                    selected: _selected.contains(v.item.albumId),
                    onTap: () {
                      if (_selecting) {
                        setState(() {
                          if (_selected.contains(v.item.albumId)) {
                            _selected.remove(v.item.albumId);
                          } else {
                            _selected.add(v.item.albumId);
                          }
                        });
                      } else {
                        _resume(v.item.albumId);
                      }
                    },
                    onLongPress: () => setState(() {
                      _selecting = true;
                      _selected.add(v.item.albumId);
                    }),
                  );
                },
              ),
          ],

          // ── 本地数据层自检（M1 准出证据；DevFlags 开启才渲染） ────
          if (localActive && DevFlags.showPanels)
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spaceMd,
                tokens.spaceLg,
                tokens.spaceMd,
                0,
              ),
              child: KeleCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.storage_rounded,
                          size: 18,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '本地数据层 · core/data',
                            style: tokens.sectionStyle,
                          ),
                        ),
                        const StageTag('M1 准出', tone: StageTone.accent),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '六张表（PRD §7.5）：${LocalDatabase.tableNames.join(' · ')}',
                      style: tokens.captionStyle,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      db.createResult?.describe ?? '表尚未创建',
                      style: tokens.numStyle,
                    ),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: _running ? null : _runDemo,
                      child: Text(_running ? '运行中…' : '运行建表 + DAO 读写 Demo'),
                    ),
                    if (_report != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: scheme.onSurface.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(tokens.radiusSm),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  _report!.ok
                                      ? Icons.check_circle_rounded
                                      : Icons.error_rounded,
                                  size: 16,
                                  color: _report!.ok
                                      ? scheme.secondary
                                      : scheme.error,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    _report!.summary,
                                    style: tokens.numStyle.copyWith(
                                      color: _report!.ok
                                          ? scheme.secondary
                                          : scheme.error,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            for (final s in _report!.steps)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 2,
                                ),
                                child: Text(
                                  '· $s',
                                  style: tokens.captionStyle.copyWith(
                                    fontFamily: 'monospace',
                                    fontSize: 11.5,
                                  ),
                                ),
                              ),
                            if (_counts.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                '表行数：${_counts.entries.map((e) => '${e.key}=${e.value}').join('  ')}',
                                style: tokens.captionStyle.copyWith(
                                  fontFamily: 'monospace',
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 在听置顶区卡片：封面 + 标题 + 进度条，点击续播。
class _ListeningCard extends StatelessWidget {
  const _ListeningCard({required this.view, required this.onTap});

  final ShelfView view;
  final void Function(String albumId) onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 140,
      child: KeleCard(
        onTap: () => onTap(view.item.albumId),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(tokens.radiusSm),
              child: SizedBox(
                width: double.infinity,
                height: 64,
                child: CoverImage(url: view.coverUrl, title: view.title),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              view.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.bodyStyle.copyWith(
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: view.lastChapterPercent / 100,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
            ),
            const SizedBox(height: 4),
            Text(
              view.totalChapters > 0
                  ? '已听 ${view.finishedCount}/${view.totalChapters}'
                  : '尚未收听',
              style: tokens.captionStyle,
            ),
          ],
        ),
      ),
    );
  }
}

/// 书架网格容器：按屏宽自适应 2~3 列，卡片等高。
///
/// 行高 = 封面（3:4）+ 文本区；文本区固定「上 8 / 标题 2 行 / 间隔 4 /
/// 进度 1 行 / 下 8」的高度，并多留 2px 余量，避免字体度量差异触发
/// 0.x px 的溢出警告条。
class _ShelfGrid extends StatelessWidget {
  const _ShelfGrid({required this.itemCount, required this.itemBuilder});

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = shelfGridColumns(constraints.maxWidth);
        final gap = tokens.spaceSm;
        final columnWidth =
            (constraints.maxWidth -
                tokens.spaceMd * 2 -
                gap * (columns - 1)) /
            columns;
        final captionLine = tokens.captionStyle.fontSize! * 1.4;
        final textHeight = 8 + _cardTitleHeight(tokens) * 2 + 4 + captionLine +
            8 +
            2;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            tokens.spaceMd,
            tokens.spaceXs,
            tokens.spaceMd,
            0,
          ),
          child: GridView.builder(
            shrinkWrap: true,
            primary: false,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            itemCount: itemCount,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: gap,
              crossAxisSpacing: gap,
              mainAxisExtent: columnWidth * 4 / 3 + textHeight,
            ),
            itemBuilder: itemBuilder,
          ),
        );
      },
    );
  }
}

/// 卡片标题单行高度（与卡片内 `Text` 的 height 1.3 保持一致）。
double _cardTitleHeight(AppTokens tokens) => tokens.bodyStyle.fontSize! * 1.3;

/// 多选态勾选圈：叠在封面左上角，带半透明底保证在任何封面上可见。
class _SelectDot extends StatelessWidget {
  const _SelectDot({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.9),
        shape: BoxShape.circle,
      ),
      child: Icon(
        selected ? Icons.check_circle_rounded : Icons.circle_outlined,
        size: 20,
        color: selected ? scheme.primary : tokens.onHairline,
      ),
    );
  }
}

/// 收藏专辑网格卡片：3:4 真实封面（居中裁切）+ 两行标题 + 单行进度。
class _AlbumShelfCard extends StatelessWidget {
  const _AlbumShelfCard({
    required this.view,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final ShelfView view;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final titleStyle = tokens.bodyStyle.copyWith(
      height: 1.3,
      fontWeight: FontWeight.w700,
      color: scheme.onSurface,
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: selecting ? null : onLongPress,
        borderRadius: BorderRadius.circular(tokens.radiusMd),
        child: KeleCard(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Stack(
                children: [
                  AspectRatio(
                    aspectRatio: 3 / 4,
                    child: CoverImage(
                      url: view.coverUrl,
                      title: view.title,
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(tokens.radiusMd - 1),
                      ),
                    ),
                  ),
                  if (selecting)
                    Positioned(
                      left: 6,
                      top: 6,
                      child: _SelectDot(selected: selected),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: double.infinity,
                      height: _cardTitleHeight(tokens) * 2,
                      child: Text(
                        view.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: titleStyle,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: view.totalChapters > 0
                                ? '已听 ${view.finishedCount}/${view.totalChapters}'
                                : '尚未收听',
                            style: tokens.captionStyle.copyWith(
                              color: scheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          TextSpan(
                            text: ' · ${view.upName}',
                            style: tokens.captionStyle,
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _ImportAction { localFile, web }

enum _MissingAction { reimport, refetch }

/// 本地书网格卡片：3:4 封面占位 + 格式角标 + 两行标题 + 单行进度。
///
/// 网格下取消左滑删除（横向滑动与网格滚动/选择手势冲突，窄卡片误删率高），
/// 保留长按进入多选，由顶部操作条统一删除。
class _LocalBookCard extends StatelessWidget {
  const _LocalBookCard({
    required this.book,
    required this.missing,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final ReaderBook book;
  final bool missing;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final titleStyle = tokens.bodyStyle.copyWith(
      height: 1.3,
      fontWeight: FontWeight.w700,
      color: scheme.onSurface,
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: selecting ? null : onLongPress,
        borderRadius: BorderRadius.circular(tokens.radiusMd),
        child: KeleCard(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Stack(
                children: [
                  AspectRatio(
                    aspectRatio: 3 / 4,
                    child: _BookCover(book: book),
                  ),
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: InfoChip(
                      book.source.label,
                      tone: StageTone.accent,
                    ),
                  ),
                  if (selecting)
                    Positioned(
                      left: 6,
                      top: 6,
                      child: _SelectDot(selected: selected),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: double.infinity,
                      height: _cardTitleHeight(tokens) * 2,
                      child: Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: titleStyle,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      missing ? '文件缺失，请重新导入' : book.progressBrief,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.captionStyle.copyWith(
                        color: missing ? scheme.error : scheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 本地书封面：M9.1 尚未提取封面（[ReaderBook.coverPath] 恒为 null），
/// 因此用主题渐变 + 书名首字占位，不做纯空白。
class _BookCover extends StatelessWidget {
  const _BookCover({required this.book});

  final ReaderBook book;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final initial = book.title.trim().isEmpty
        ? '书'
        : book.title.trim().characters.first;

    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary.withValues(alpha: 0.85),
            scheme.secondary.withValues(alpha: 0.65),
          ],
        ),
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(tokens.radiusMd - 1),
        ),
      ),
      child: Text(
        initial,
        style: TextStyle(
          color: scheme.onPrimary,
          fontSize: 30,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// 分栏空态（复用全局 EmptyState 视觉规范）。
class _SectionEmptyState extends StatelessWidget {
  const _SectionEmptyState({
    required this.spec,
    required this.icon,
    required this.onAction,
  });

  final ShelfEmptySpec spec;
  final IconData icon;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: icon,
    title: spec.title,
    message: spec.message,
    actionLabel: spec.actionLabel,
    onAction: onAction,
  );
}
