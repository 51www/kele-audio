import 'dart:convert';

/// PDF 页码映射侧车（`books/{id}/pdf_pages.json`，M10.2）。
///
/// 重排后的 EPUB 以「每 [pagesPerChapter] 页一章」组织，侧车记录
/// 章节 ↔ 原始 PDF 页码的对应关系，供阅读页显示页码与跳页使用。
class PdfPageMap {
  const PdfPageMap({
    required this.pageCount,
    required this.pagesPerChapter,
    required this.chapters,
  });

  /// 侧车文件名。
  static const String fileName = 'pdf_pages.json';

  final int pageCount;
  final int pagesPerChapter;
  final List<PdfPageChapter> chapters;

  /// 按固定页数分组构造。
  factory PdfPageMap.grouped({
    required int pageCount,
    required int pagesPerChapter,
  }) {
    final safeSize = pagesPerChapter <= 0 ? 1 : pagesPerChapter;
    final chapters = <PdfPageChapter>[];
    for (var start = 1; start <= pageCount; start += safeSize) {
      final end = (start + safeSize - 1).clamp(1, pageCount);
      chapters.add(
        PdfPageChapter(
          chapterIndex: chapters.length,
          startPage: start,
          endPage: end,
        ),
      );
    }
    return PdfPageMap(
      pageCount: pageCount,
      pagesPerChapter: safeSize,
      chapters: chapters,
    );
  }

  /// 页码（1 基）落在哪一章；超出范围时夹到首/末章。
  int chapterForPage(int page) {
    if (chapters.isEmpty) return 0;
    for (final chapter in chapters) {
      if (page >= chapter.startPage && page <= chapter.endPage) {
        return chapter.chapterIndex;
      }
    }
    return page < 1 ? 0 : chapters.last.chapterIndex;
  }

  PdfPageChapter? chapterAt(int index) {
    if (index < 0 || index >= chapters.length) return null;
    return chapters[index];
  }

  /// 章节页码文案：单页显示「第 3 页」，多页显示「第 1–20 页」。
  String labelForChapter(int index) {
    final chapter = chapterAt(index);
    if (chapter == null) return '第 ? 页';
    if (chapter.startPage == chapter.endPage) {
      return '第 ${chapter.startPage} 页';
    }
    return '第 ${chapter.startPage}–${chapter.endPage} 页';
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'pageCount': pageCount,
    'pagesPerChapter': pagesPerChapter,
    'chapters': [
      for (final chapter in chapters) chapter.toJson(),
    ],
  };

  String encode() => jsonEncode(toJson());

  static PdfPageMap? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      return PdfPageMap.fromJson(json);
    } on FormatException {
      return null;
    }
  }

  factory PdfPageMap.fromJson(Map<String, dynamic> json) {
    final chaptersJson = json['chapters'];
    final chapters = <PdfPageChapter>[];
    if (chaptersJson is List) {
      for (final item in chaptersJson) {
        if (item is Map<String, dynamic>) {
          chapters.add(PdfPageChapter.fromJson(item));
        }
      }
    }
    return PdfPageMap(
      pageCount: (json['pageCount'] as num?)?.toInt() ?? 0,
      pagesPerChapter: (json['pagesPerChapter'] as num?)?.toInt() ?? 1,
      chapters: chapters,
    );
  }
}

class PdfPageChapter {
  const PdfPageChapter({
    required this.chapterIndex,
    required this.startPage,
    required this.endPage,
  });

  final int chapterIndex;

  /// 1 基起始页。
  final int startPage;

  /// 1 基结束页（含）。
  final int endPage;

  Map<String, dynamic> toJson() => {
    'chapterIndex': chapterIndex,
    'startPage': startPage,
    'endPage': endPage,
  };

  factory PdfPageChapter.fromJson(Map<String, dynamic> json) => PdfPageChapter(
    chapterIndex: (json['chapterIndex'] as num?)?.toInt() ?? 0,
    startPage: (json['startPage'] as num?)?.toInt() ?? 1,
    endPage: (json['endPage'] as num?)?.toInt() ?? 1,
  );
}
