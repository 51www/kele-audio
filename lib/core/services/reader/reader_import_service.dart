import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../domain/reader_book.dart';
import 'book_file_store.dart';
import 'book_store.dart';
import 'epub_importer.dart';
import 'local_book_cover.dart';
import 'pdf_importer.dart';
import 'pdf_page_map.dart';
import 'reader_activity_store.dart';
import 'reader_progress_store.dart';
import 'txt_importer.dart';
import 'txt_to_epub.dart';
import 'web_article_importer.dart';

enum ReaderImportError {
  emptyFile,
  unsupportedFormat,
  invalidContent,
  network,
  pdfScanned,
  tooLarge,
  tooManyPages,
  pdfEncrypted,
  cancelled,
}

class ReaderImportException implements Exception {
  const ReaderImportException(this.kind, this.message);

  final ReaderImportError kind;
  final String message;

  @override
  String toString() => message;
}

/// 网页导入结果：书籍 + 内容完整性提示（可为空）。
class WebImportOutcome {
  const WebImportOutcome({required this.book, this.notice});

  final ReaderBook book;
  final String? notice;
}

/// 三路导入的编排层（docs/reader-design.md §3）：
/// TXT / EPUB / 网页 → 统一 EPUB 落盘 → 元数据入库。
class ReaderImportService {
  ReaderImportService({
    required this.books,
    required this.activity,
    this.progress,
  });

  final ReaderBookStore books;
  final ReaderActivityStore activity;
  final ReaderProgressStore? progress;

  static const String bookFileName = 'book.epub';

  /// 旧书补封面是否在进行中（避免书架重复进出时并发跑两轮）。
  bool _coverBackfillRunning = false;

  /// TXT 导入：编码识别 → 清洗 → 切章 → 打包 EPUB。
  Future<ReaderBook> importTxt({
    required Uint8List bytes,
    required String fileName,
  }) async {
    if (bytes.isEmpty) {
      throw const ReaderImportException(ReaderImportError.emptyFile, '文件为空');
    }
    final fallbackTitle = _titleFromFileName(fileName);
    final parsed = TxtImporter.parse(bytes, fallbackTitle: fallbackTitle);
    if (parsed.chapters.isEmpty) {
      throw const ReaderImportException(
        ReaderImportError.invalidContent,
        '未读取到正文内容',
      );
    }

    final epub = EpubBuilder.build(
      title: parsed.title,
      chapters: [
        for (final chapter in parsed.chapters)
          EpubChapter(
            title: chapter.title,
            html: EpubBuilder.textToHtml(chapter.content),
          ),
      ],
    );

    final id = EpubBuilder.newBookId();
    await saveReaderBookFile(id, epub, fileName: bookFileName);

    final book = ReaderBook(
      id: id,
      title: parsed.title,
      source: ReaderBookSource.localTxt,
      fileName: bookFileName,
      chapterCount: parsed.chapters.length,
      addedAt: DateTime.now(),
    );
    await books.add(book);
    return book;
  }

  /// EPUB 导入：zip/OPF 校验后整本拷贝。
  Future<ReaderBook> importEpub({
    required Uint8List bytes,
    required String fileName,
  }) async {
    if (bytes.isEmpty) {
      throw const ReaderImportException(ReaderImportError.emptyFile, '文件为空');
    }
    final fallbackTitle = _titleFromFileName(fileName);
    EpubMeta meta;
    try {
      meta = EpubImporter.inspect(bytes, fallbackTitle: fallbackTitle);
    } on EpubImportException catch (e) {
      throw ReaderImportException(ReaderImportError.invalidContent, e.message);
    }

    final id = EpubBuilder.newBookId();
    await saveReaderBookFile(id, bytes, fileName: bookFileName);
    // 封面是加分项：解析/落盘失败一律静默跳过，回退书架首字占位。
    final coverPath = await LocalBookCover.save(id, meta.coverBytes);

    final book = ReaderBook(
      id: id,
      title: meta.title,
      author: meta.author,
      source: ReaderBookSource.localEpub,
      fileName: bookFileName,
      chapterCount: meta.chapterCount,
      coverPath: coverPath,
      addedAt: DateTime.now(),
    );
    await books.add(book);
    return book;
  }

  /// 旧书补封面：只处理缺封面的本地 EPUB，逐本独立失败，不影响其它书。
  ///
  /// 由书架页首帧后触发一次；[books] 里已有封面文件的直接跳过。
  Future<void> backfillLocalCovers() async {
    if (_coverBackfillRunning) return;
    _coverBackfillRunning = true;
    try {
      for (final book in books.books) {
        if (book.source != ReaderBookSource.localEpub) continue;
        final hasCoverFile = await readerBookFileExists(
          book.id,
          LocalBookCover.fileName,
        );
        if (book.coverPath != null && hasCoverFile) continue;

        Uint8List? raw;
        try {
          final bytes = await readReaderBookFile(book.id, book.fileName);
          if (bytes == null) continue;
          raw = EpubImporter.readCoverQuietly(bytes);
        } catch (_) {
          continue;
        }
        if (raw == null) continue;

        final path = await LocalBookCover.save(book.id, raw);
        if (path == null) continue;
        await books.upsert(book.copyWith(coverPath: path));
      }
    } catch (e) {
      debugPrint('[reader] 旧书补封面中断：$e');
    } finally {
      _coverBackfillRunning = false;
    }
  }

  /// 网页文章导入（抓取 + 切章 + EPUB 快照）。
  Future<WebImportOutcome> importWebUrl(String url) async {
    WebArticleImportData data;
    try {
      data = await WebArticleImporter.fetch(url);
    } on WebImportException catch (e) {
      throw ReaderImportException(_mapWebError(e.kind), e.message);
    }

    final epub = EpubBuilder.build(
      title: data.title,
      author: data.author,
      chapters: data.chapters,
    );

    final id = EpubBuilder.newBookId();
    await saveReaderBookFile(id, epub, fileName: bookFileName);

    final book = ReaderBook(
      id: id,
      title: data.title,
      author: data.author,
      source: ReaderBookSource.webArticle,
      originUrl: data.originUrl,
      fileName: bookFileName,
      chapterCount: data.chapters.length,
      addedAt: DateTime.now(),
    );
    await books.add(book);
    return WebImportOutcome(book: book, notice: data.notice);
  }

  /// 「重新抓取」：覆盖快照、保留导入时间与阅读进度。
  Future<WebImportOutcome> refreshWeb(ReaderBook old) async {
    final url = old.originUrl;
    if (url == null || url.isEmpty) {
      throw const ReaderImportException(
        ReaderImportError.invalidContent,
        '缺少原始链接，无法重新抓取',
      );
    }
    WebArticleImportData data;
    try {
      data = await WebArticleImporter.fetch(url);
    } on WebImportException catch (e) {
      throw ReaderImportException(_mapWebError(e.kind), e.message);
    }

    final epub = EpubBuilder.build(
      title: data.title,
      author: data.author,
      chapters: data.chapters,
    );
    await saveReaderBookFile(old.id, epub, fileName: old.fileName);

    final updated = old.copyWith(
      title: data.title,
      author: data.author,
      originUrl: data.originUrl,
      chapterCount: data.chapters.length,
      lastChapterIndex: old.lastChapterIndex.clamp(0, data.chapters.length - 1),
    );
    await books.upsert(updated);
    return WebImportOutcome(book: updated, notice: data.notice);
  }

  /// PDF 导入第一步：解析文字层并做质量判定（扫描件在此被拦截）。
  Future<PdfImportData> inspectPdf({
    required String path,
    required String fileName,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    try {
      return await PdfImporter.parse(
        path: path,
        fileName: fileName,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
    } on PdfImportException catch (e) {
      throw ReaderImportException(_mapPdfError(e.problem), e.message);
    }
  }

  /// PDF 导入第二步：段落化 → 内部 EPUB + 页码侧车 → 元数据入库。
  ///
  /// 逐段 `<p>` 保证 TTS 按段落朗读，不会把整章当成一段。
  Future<ReaderBook> importPdf({
    required PdfImportData data,
    required String fileName,
  }) async {
    final epub = EpubBuilder.build(
      title: data.title,
      chapters: [
        for (final chapter in data.chapters)
          EpubChapter(
            title: chapter.title,
            html: EpubBuilder.textToHtml(chapter.paragraphs.join('\n\n')),
          ),
      ],
    );

    final id = EpubBuilder.newBookId();
    await saveReaderBookFile(id, epub, fileName: bookFileName);
    await saveReaderBookFile(
      id,
      Uint8List.fromList(utf8.encode(data.pageMap.encode())),
      fileName: PdfPageMap.fileName,
    );

    final book = ReaderBook(
      id: id,
      title: data.title,
      source: ReaderBookSource.localPdf,
      fileName: bookFileName,
      chapterCount: data.chapters.length,
      pdfPageCount: data.inspection.pageCount,
      pdfQuality: data.inspection.quality,
      addedAt: DateTime.now(),
    );
    await books.add(book);
    return book;
  }

  static ReaderImportError _mapPdfError(PdfImportProblem problem) =>
      switch (problem) {
        PdfImportProblem.unsupported => ReaderImportError.unsupportedFormat,
        PdfImportProblem.tooLarge => ReaderImportError.tooLarge,
        PdfImportProblem.tooManyPages => ReaderImportError.tooManyPages,
        PdfImportProblem.encrypted => ReaderImportError.pdfEncrypted,
        PdfImportProblem.scanned => ReaderImportError.pdfScanned,
        PdfImportProblem.cancelled => ReaderImportError.cancelled,
        PdfImportProblem.unreadable => ReaderImportError.invalidContent,
      };

  /// 确认删除：清理书籍文件、进度、历史与时长日志。
  Future<void> purge(ReaderBook book) async {
    await deleteReaderBookDir(book.id);
    await activity.removeBook(book.id);
    await progress?.remove(book.id);
    await books.purge(book.id);
  }

  static ReaderImportError _mapWebError(WebImportError error) {
    return switch (error) {
      WebImportError.invalidUrl => ReaderImportError.invalidContent,
      WebImportError.network => ReaderImportError.network,
      WebImportError.timeout => ReaderImportError.network,
      WebImportError.empty => ReaderImportError.invalidContent,
      WebImportError.blocked => ReaderImportError.invalidContent,
      WebImportError.unsupported => ReaderImportError.unsupportedFormat,
    };
  }

  static String _titleFromFileName(String fileName) {
    final base = fileName.split(RegExp(r'[\\/]')).last;
    final dot = base.lastIndexOf('.');
    final title = dot > 0 ? base.substring(0, dot) : base;
    return title.trim().isEmpty ? '未命名书籍' : title.trim();
  }
}
