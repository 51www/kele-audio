import 'package:pdfrx/pdfrx.dart';

import 'pdf_file_probe.dart';
import 'pdf_page_map.dart';
import 'pdf_quality.dart';
import 'pdf_text_normalizer.dart';

/// PDF 导入失败原因（供编排层映射成用户文案）。
enum PdfImportProblem {
  unsupported,
  tooLarge,
  tooManyPages,
  encrypted,
  scanned,
  unreadable,
  cancelled,
}

class PdfImportException implements Exception {
  const PdfImportException(this.problem, this.message);

  final PdfImportProblem problem;
  final String message;

  @override
  String toString() => message;
}

/// 一章（若干页）的清洗结果。
class PdfChapterData {
  const PdfChapterData({required this.title, required this.paragraphs});

  final String title;

  /// 已清洗段落；空章节（整组扫描页）为空列表。
  final List<String> paragraphs;
}

/// PDF 解析结果：质量判定 + 分章段落 + 页码映射。
class PdfImportData {
  const PdfImportData({
    required this.title,
    required this.inspection,
    required this.pageMap,
    required this.chapters,
  });

  final String title;
  final PdfInspection inspection;
  final PdfPageMap pageMap;
  final List<PdfChapterData> chapters;
}

/// PDF 文字层导入（M10.1）。
///
/// 只支持带文字层的 PDF：不做 OCR，不渲染扫描页；整本抽不到文字时由
/// 调用方拦截。阅读侧统一转成内部 EPUB（逐段 `<p>`）走既有阅读/朗读管线。
class PdfImporter {
  const PdfImporter._();

  /// 每章对应的页数（章节粒度 = 页组，页码映射按此写入侧车）。
  static const int pagesPerChapter = 20;

  static Future<PdfImportData> parse({
    required String path,
    required String fileName,
    String? title,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final fileBytes = PdfFileProbe.lengthOf(path);
    if (fileBytes < 0) {
      throw const PdfImportException(
        PdfImportProblem.unsupported,
        '当前平台不支持 PDF 导入',
      );
    }
    if (fileBytes <= 0) {
      throw const PdfImportException(PdfImportProblem.unreadable, '文件为空');
    }
    if (fileBytes > PdfLimits.maxFileBytes) {
      throw const PdfImportException(
        PdfImportProblem.tooLarge,
        'PDF 超过 100 MB 上限，暂不支持导入',
      );
    }

    final displayTitle = _titleOf(fileName, title);
    PdfDocument? document;
    try {
      document = await PdfDocument.openFile(path);
      final pageCount = document.pages.length;
      if (pageCount <= 0) {
        throw const PdfImportException(PdfImportProblem.unreadable, 'PDF 没有可读取的页面');
      }
      if (pageCount > PdfLimits.maxPageCount) {
        throw PdfImportException(
          PdfImportProblem.tooManyPages,
          'PDF 共 $pageCount 页，超过 2000 页上限，暂不支持导入',
        );
      }

      final pages = <PdfExtractedPage>[];
      for (var i = 0; i < pageCount; i++) {
        if (isCancelled?.call() ?? false) {
          throw const PdfImportException(PdfImportProblem.cancelled, '已取消导入');
        }
        final page = document.pages[i];
        // 结构化文本包含阅读顺序分析（多栏按栏排序），比 loadText 更适合重排。
        final text = await page.loadStructuredText();
        pages.add(PdfExtractedPage(pageNumber: i + 1, text: text.fullText));
        onProgress?.call((i + 1) / pageCount);
      }

      final inspection = PdfQualityAnalyzer.analyze(
        fileName: fileName,
        path: path,
        fileBytes: fileBytes,
        pageCount: pageCount,
        pages: pages,
      );
      if (inspection.scanned) {
        throw const PdfImportException(
          PdfImportProblem.scanned,
          '这是扫描件（没有可抽取的文字层），当前版本不支持 OCR',
        );
      }

      final pageMap = PdfPageMap.grouped(
        pageCount: pageCount,
        pagesPerChapter: pagesPerChapter,
      );
      final chapters = <PdfChapterData>[];
      for (var start = 0; start < pageCount; start += pagesPerChapter) {
        final end = (start + pagesPerChapter).clamp(0, pageCount);
        final texts = [
          for (var i = start; i < end; i++) pages[i].text,
        ];
        final paragraphs = PdfTextNormalizer.paragraphsFromPages(texts);
        final chapterTitle = _chapterTitle(start + 1, end);
        chapters.add(
          PdfChapterData(title: chapterTitle, paragraphs: paragraphs),
        );
      }

      return PdfImportData(
        title: displayTitle,
        inspection: inspection,
        pageMap: pageMap,
        chapters: chapters,
      );
    } on PdfImportException {
      rethrow;
    } on PdfPasswordException {
      throw const PdfImportException(
        PdfImportProblem.encrypted,
        'PDF 已加密，暂不支持导入',
      );
    } catch (error) {
      throw PdfImportException(
        PdfImportProblem.unreadable,
        'PDF 解析失败：${_short(error)}',
      );
    } finally {
      await document?.dispose();
    }
  }

  static String _chapterTitle(int startPage, int endPage) =>
      startPage == endPage ? '第 $startPage 页' : '第 $startPage–$endPage 页';

  static String _titleOf(String fileName, String? title) {
    final provided = title?.trim();
    if (provided != null && provided.isNotEmpty) return provided;
    final base = fileName.split(RegExp(r'[\\/]')).last;
    final dot = base.lastIndexOf('.');
    final name = dot > 0 ? base.substring(0, dot) : base;
    return name.trim().isEmpty ? '未命名 PDF' : name.trim();
  }

  static String _short(Object error) {
    final text = error.toString();
    return text.length > 120 ? '${text.substring(0, 120)}…' : text;
  }
}
