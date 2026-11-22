import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/dev_flags.dart';
import '../../app/di.dart';
import '../../app/theme/app_tokens.dart';
import '../../app/widgets/common.dart';
import '../../app/widgets/local_cover_image.dart';
import '../../app/widgets/recent_records.dart';
import '../../core/api/album_source.dart';
import '../../core/data/dao_demo.dart';
import '../../core/data/daos.dart';
import '../../core/data/local_database.dart';
import '../../core/domain/album.dart';
import '../../core/domain/reader_book.dart';
import '../../core/services/player/player_service.dart';
import '../../core/services/reader/book_store.dart';
import '../../core/services/reader/mobi_importer.dart';
import '../../core/services/reader/pdf_quality.dart';
import '../../core/services/reader/reader_import_service.dart';
import '../../core/services/reader/reader_progress_store.dart';
import '../../core/services/recent_records.dart';
import '../../core/services/shelf_controller.dart';
import '../discover/album_card.dart';
import '../reader/web_import_sheet.dart';
import 'shelf_tab.dart';

/// Tab 2 书架（PRD §5.3，M4 接入；分栏已合并为单一网格）。
///
/// 结构：
/// - 三列等宽网格：本地书与收藏专辑一起按同一套排序展示；
/// - 来源靠封面内角标区分（本地书显示格式，收藏专辑显示来源图标）；
/// - 排序：最近 / 收藏时间 / 标题（两类条目共用）；
/// - 长按多选删除（含全选），本地书删除时同时清理本地文件；
/// - 空态引导。
///
/// 数据来自 [ShelfController.buildViews]（shelf × album × play_history 联合查询），
/// 每次 build 同步重读，保证切回页面 / 收藏状态变化后读到最新进度。
class ShelfPage extends StatefulWidget {
  const ShelfPage({super.key});

  @override
  State<ShelfPage> createState() => _ShelfPageState();
}

/// MOBI 容器家族的扩展名（AZW 与 MOBI 同为 PalmDB；AZW3 / KF8 是另一种容器）。
const Set<String> _mobiExtensions = {'mobi', 'azw'};

enum _SortMode { recent, collected, title }

extension _SortModeX on _SortMode {
  String get label => switch (this) {
    _SortMode.recent => '最近',
    _SortMode.collected => '收藏时间',
    _SortMode.title => '标题',
  };
}

/// 合并列表的统一条目：本地书 + 收藏专辑，排序/多选共用同一套逻辑。
sealed class _ShelfEntry {
  int get recentAt;
  int get collectedAt;
  String get title;
}

class _BookEntry extends _ShelfEntry {
  _BookEntry(this.book);

  final ReaderBook book;

  @override
  int get recentAt => (book.lastReadAt ?? book.addedAt).millisecondsSinceEpoch;

  @override
  int get collectedAt => book.addedAt.millisecondsSinceEpoch;

  @override
  String get title => book.title;
}

class _AlbumEntry extends _ShelfEntry {
  _AlbumEntry(this.view);

  final ShelfView view;

  @override
  int get recentAt => view.lastPlayedAt;

  @override
  int get collectedAt => view.collectedAt;

  @override
  String get title => view.title;
}

class _ShelfPageState extends State<ShelfPage> {
  _SortMode _sort = _SortMode.recent;

  final ScrollController _scroll = ScrollController();

  // 多选删除态（合并列表后专辑与本地书各用一个集合，顶部统一计数）
  bool _selecting = false;
  final Set<String> _selectedAlbums = {};
  final Set<String> _selectedBooks = {};

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
    // 旧版本导入的本地 EPUB 没有封面：首帧后静默补一次（单本失败跳过）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _backfillLocalCovers());
  }

  Future<void> _backfillLocalCovers() async {
    if (!mounted) return;
    await context.read<ReaderImportService>().backfillLocalCovers();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
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
        ..showSnackBar(
          const SnackBar(
            content: Text('正在获取专辑信息…'),
            duration: Duration(seconds: 2),
          ),
        );
      album = await _fetchAlbumMeta(albumId);
      messenger.hideCurrentSnackBar();
      if (album == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: const Text('本地缺少这本专辑的信息（旧版备份未包含）。可重试补抓，或到发现页重新搜索后收藏。'),
              action: SnackBarAction(
                label: '重试',
                onPressed: () => _resume(albumId),
              ),
              duration: const Duration(seconds: 8),
            ),
          );
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

  // ───────────────────────────────────────────────── 本地书（M9.1）
  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _cancelSelectionAction() => TextButton(
    onPressed: () => setState(() {
      _selecting = false;
      _selectedAlbums.clear();
      _selectedBooks.clear();
    }),
    child: const Text('取消'),
  );

  Widget _sortAction() => PopupMenuButton<_SortMode>(
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

  void _toggleBook(String id) => setState(() {
    if (!_selectedBooks.remove(id)) _selectedBooks.add(id);
  });

  void _toggleAlbum(String id) => setState(() {
    if (!_selectedAlbums.remove(id)) _selectedAlbums.add(id);
  });

  void _startSelectingBook(String id) => setState(() {
    _selecting = true;
    _selectedBooks.add(id);
  });

  void _startSelectingAlbum(String id) => setState(() {
    _selecting = true;
    _selectedAlbums.add(id);
  });

  /// 合并列表的多选删除：收藏专辑移出书架，本地书同时删除本地文件。
  Future<void> _deleteSelected() async {
    final albumIds = [..._selectedAlbums];
    final bookIds = [..._selectedBooks];
    if (albumIds.isEmpty && bookIds.isEmpty) return;
    final total = albumIds.length + bookIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('从书架删除'),
        content: Text(
          '将删除 $total 项'
          '${bookIds.isEmpty ? '。' : '，其中 ${bookIds.length} 本本地书会同时删除本地文件。'}',
        ),
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
        await service.purge(book);
      }
    }
    if (!mounted) return;
    setState(() {
      _selecting = false;
      _selectedAlbums.clear();
      _selectedBooks.clear();
    });
    _toast('已删除 $total 项');
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
              subtitle: const Text('TXT / EPUB / PDF / MOBI（PDF 仅文字层）'),
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
      allowedExtensions: const ['txt', 'epub', 'pdf', 'mobi', 'azw'],
      withData: kIsWeb,
    );
    final file = result?.files.isEmpty == false ? result!.files.first : null;
    if (file == null) return;
    if (!mounted) return;

    final extension = (file.extension ?? '').toLowerCase();
    final isMobi = _mobiExtensions.contains(extension);
    if (extension == 'pdf') {
      await _importPdf(file);
      return;
    }
    if (extension != 'txt' && extension != 'epub' && !isMobi) {
      if (mounted) _toast('仅支持 TXT / EPUB / PDF / MOBI 文件');
      return;
    }
    if (isMobi && file.size > MobiImporter.maxFileBytes) {
      if (mounted) _toast('MOBI 文件过大（上限 64 MB）');
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
      } else if (isMobi) {
        book = await service.importMobi(bytes: bytes, fileName: file.name);
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
        message:
            '当前上限 100 MB，该文件约 '
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
          message:
              '该文件没有可抽取的文字层（每页都是图片）。\n'
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

  // ───────────────────────────────────────────────────────── 排序
  /// 合并列表排序：本地书与收藏专辑共用三种口径，避免两套逻辑分叉。
  List<_ShelfEntry> _sortedEntries(
    List<ShelfView> views,
    List<ReaderBook> books,
  ) {
    final entries = <_ShelfEntry>[
      for (final view in views) _AlbumEntry(view),
      for (final book in books) _BookEntry(book),
    ];
    switch (_sort) {
      case _SortMode.recent:
        entries.sort((a, b) => b.recentAt.compareTo(a.recentAt));
      case _SortMode.collected:
        entries.sort((a, b) => b.collectedAt.compareTo(a.collectedAt));
      case _SortMode.title:
        entries.sort((a, b) => a.title.compareTo(b.title));
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    // watch：收藏状态变化（详情/播放页 toggle）实时反映到书架
    final shelf = context.watch<ShelfController>();
    final db = context.read<LocalDatabase>();
    final bookStore = context.watch<ReaderBookStore>();

    final views = shelf.buildViews();
    // 本地书来源统一走 [shelfOriginOf]，避免页面里再散落一套归类判断。
    final localBooks = <ReaderBook>[
      for (final book in bookStore.books)
        if (shelfOriginOf(book.source) != null) book,
    ];
    final entries = _sortedEntries(views, localBooks);
    final albumIds = [for (final view in views) view.item.albumId];
    final bookIds = [for (final book in localBooks) book.id];
    final selectedCount = _selectedAlbums.length + _selectedBooks.length;
    final allSelected = entries.isNotEmpty && selectedCount == entries.length;

    // 续读条：复用现有阅读 / 播放进度，取最近 1 条未读完的书或专辑。
    final continueRecord = RecentRecordsService(
      books: bookStore,
      progress: context.read<ReaderProgressStore>(),
      daos: context.read<Daos>(),
      kv: context.read<AppServices>().kv,
    ).latestUnfinished();

    return SafeArea(
      bottom: false,
      child: ListView(
        controller: _scroll,
        // 底部留白与常驻播放条保持独立安全间距（播放条在页面之外挂载）。
        padding: EdgeInsets.only(bottom: tokens.spaceLg),
        children: [
          PageHeader(
            title: '书架',
            actions: _selecting
                ? [_cancelSelectionAction()]
                : [
                    IconButton(
                      tooltip: '导入',
                      onPressed: _importing ? null : _showImportMenu,
                      icon: _importing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.library_add_outlined),
                    ),
                    IconButton(
                      tooltip: '选择删除',
                      onPressed: () => setState(() {
                        _selecting = true;
                        _selectedAlbums.clear();
                        _selectedBooks.clear();
                      }),
                      icon: const Icon(Icons.checklist_rounded),
                    ),
                    _sortAction(),
                  ],
          ),

          // ── 续读条：最近一条未读完的书 / 专辑（最多 1 条）───────
          if (!_selecting && continueRecord != null)
            ContinueRecordBar(
              record: continueRecord,
              onTap: () => openRecentRecord(context, continueRecord),
            ),

          // ── 多选删除操作条 ───────────────────────────────────────
          if (_selecting)
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spaceMd,
                0,
                tokens.spaceMd,
                tokens.spaceMd,
              ),
              child: KeleCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Text('已选 $selectedCount 项', style: tokens.bodyStyle),
                    const Spacer(),
                    TextButton(
                      onPressed: () => setState(() {
                        if (allSelected) {
                          _selectedAlbums.clear();
                          _selectedBooks.clear();
                        } else {
                          _selectedAlbums
                            ..clear()
                            ..addAll(albumIds);
                          _selectedBooks
                            ..clear()
                            ..addAll(bookIds);
                        }
                      }),
                      child: Text(allSelected ? '取消全选' : '全选'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: selectedCount == 0 ? null : _deleteSelected,
                      child: const Text('删除'),
                    ),
                  ],
                ),
              ),
            ),

          // ── 合并网格：本地书 + 收藏专辑 ───────────────────────────
          if (entries.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: tokens.spaceMd),
              child: EmptyState(
                icon: Icons.library_books_outlined,
                title: shelfEmptySpec.title,
                message: shelfEmptySpec.message,
                actionLabel: shelfEmptySpec.actionLabel,
                onAction: _showImportMenu,
              ),
            )
          else
            _ShelfGrid(
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                switch (entry) {
                  case _BookEntry(:final book):
                    final missing = bookStore.isMissing(book.id);
                    return _ShelfCard(
                      cover: _BookCover(book: book),
                      badge: _CoverBadge.text(book.source.label),
                      title: book.title,
                      progress: missing ? '文件缺失，请重新导入' : book.progressBrief,
                      progressColor: missing ? scheme.error : scheme.primary,
                      selecting: _selecting,
                      selected: _selectedBooks.contains(book.id),
                      onTap: () {
                        if (_selecting) {
                          _toggleBook(book.id);
                        } else {
                          _openLocalBook(book);
                        }
                      },
                      onLongPress: () => _startSelectingBook(book.id),
                    );
                  case _AlbumEntry(:final view):
                    return _ShelfCard(
                      cover: CoverImage(url: view.coverUrl, title: view.title),
                      badge: const _CoverBadge.icon(
                        Icons.headphones_rounded,
                        semanticLabel: '收藏专辑',
                      ),
                      title: view.title,
                      progress: view.totalChapters > 0
                          ? '已听 ${view.finishedCount}/${view.totalChapters}'
                                ' · ${view.upName}'
                          : '尚未收听 · ${view.upName}',
                      progressColor: scheme.primary,
                      selecting: _selecting,
                      selected: _selectedAlbums.contains(view.item.albumId),
                      onTap: () {
                        if (_selecting) {
                          _toggleAlbum(view.item.albumId);
                        } else {
                          _resume(view.item.albumId);
                        }
                      },
                      onLongPress: () =>
                          _startSelectingAlbum(view.item.albumId),
                    );
                }
              },
            ),

          // ── 本地数据层自检（M1 准出证据；DevFlags 开启才渲染） ────
          if (DevFlags.showPanels)
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

/// 书架网格：固定三列等宽，列间距与左右安全边距相等。
///
/// 行高 = 满铺封面（3:4）+ 文案区（标题 + 紧凑进度），卡片内部不额外留白，
/// 行间距明显大于封面与标题之间的间距，整页节奏一致。
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
        final gap = tokens.spaceMd;
        final columnWidth =
            (constraints.maxWidth - tokens.spaceMd * 2 - gap * (columns - 1)) /
            columns;
        // +1px 余量，避免字体度量差异触发 0.x px 的溢出告警。
        final mainAxisExtent = columnWidth * 4 / 3 + _shelfTextHeight() + 1;
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
              mainAxisSpacing: tokens.spaceLg,
              crossAxisSpacing: gap,
              mainAxisExtent: mainAxisExtent,
            ),
            itemBuilder: itemBuilder,
          ),
        );
      },
    );
  }
}

/// 卡片正文高度（标题间距 6 + 单行标题 + 3 + 单行进度），与卡片内 SizedBox 同步。
const double _shelfTitleSize = 13;
const double _shelfProgressSize = 11.5;

double _shelfTextHeight() =>
    6 + _shelfTitleSize * 1.3 + 3 + _shelfProgressSize * 1.4;

/// 统一书架卡片：满铺裁切封面 + 单行标题（+ 单行紧凑进度）。
///
/// 无描边、无阴影、无悬浮位移；标题左对齐封面左边缘，卡内无额外内边距。
class _ShelfCard extends StatelessWidget {
  const _ShelfCard({
    required this.cover,
    required this.badge,
    required this.title,
    required this.progress,
    required this.progressColor,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final Widget cover;

  /// 封面内角标：不占文本行，也不改变卡片等高。
  final Widget badge;

  final String title;
  final String progress;
  final Color progressColor;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: selecting ? null : onLongPress,
        borderRadius: BorderRadius.circular(tokens.radiusSm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: 3 / 4,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(tokens.radiusSm),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    cover,
                    Positioned(right: 4, bottom: 4, child: badge),
                    if (selecting)
                      Positioned(
                        left: 4,
                        top: 4,
                        child: _SelectDot(selected: selected),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              height: _shelfTitleSize * 1.3,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: _shelfTitleSize,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 3),
            SizedBox(
              width: double.infinity,
              height: _shelfProgressSize * 1.4,
              child: Text(
                progress,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tokens.captionStyle.copyWith(
                  fontSize: _shelfProgressSize,
                  height: 1.4,
                  color: progressColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 封面内角标：半透明底色保证在任何封面上都清晰可读。
class _CoverBadge extends StatelessWidget {
  const _CoverBadge.text(this.text) : icon = null, semanticLabel = null;

  const _CoverBadge.icon(this.icon, {this.semanticLabel}) : text = null;

  final String? text;
  final IconData? icon;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: semanticLabel,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: 0.86),
          borderRadius: BorderRadius.circular(4),
        ),
        child: text != null
            ? Text(
                text!,
                style: TextStyle(
                  fontSize: 10,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              )
            : Icon(icon, size: 12, color: scheme.onSurface),
      ),
    );
  }
}

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
        size: 18,
        color: selected ? scheme.primary : tokens.onHairline,
      ),
    );
  }
}

enum _ImportAction { localFile, web }

enum _MissingAction { reimport, refetch }

/// 本地书封面：优先展示 EPUB 解析出的真实封面（`books/{id}/cover.jpg`），
/// 没有封面（TXT/PDF/MOBI/网页/解析失败）时回退主题渐变 + 书名首字占位。
class _BookCover extends StatelessWidget {
  const _BookCover({required this.book});

  final ReaderBook book;

  @override
  Widget build(BuildContext context) {
    final placeholder = _letterCover(context);
    final coverPath = book.coverPath;
    if (coverPath == null || coverPath.isEmpty) return placeholder;
    return localCoverImage(path: coverPath, placeholder: placeholder);
  }

  Widget _letterCover(BuildContext context) {
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
