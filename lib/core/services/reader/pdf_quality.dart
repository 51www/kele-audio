import '../../domain/reader_book.dart';

/// PDF 导入上限（M10.0 评估结论，先按此值落地）。
class PdfLimits {
  const PdfLimits._();

  /// 单文件上限 100 MB。
  static const int maxFileBytes = 100 * 1024 * 1024;

  /// 页数上限 2000 页。
  static const int maxPageCount = 2000;
}

/// 单页抽取结果。
class PdfExtractedPage {
  const PdfExtractedPage({required this.pageNumber, required this.text});

  /// 1 基页码。
  final int pageNumber;
  final String text;
}

/// 文字层判定结果。
///
/// 判定只基于抽取文本本身，不做 OCR；因此「扫描件」= 全本几乎抽不到字符。
class PdfInspection {
  const PdfInspection({
    required this.fileName,
    required this.path,
    required this.fileBytes,
    required this.pageCount,
    required this.pages,
    required this.quality,
    required this.scanned,
    required this.totalChars,
    required this.nonEmptyPages,
    required this.suspiciousRatio,
  });

  final String fileName;
  final String path;
  final int fileBytes;
  final int pageCount;
  final List<PdfExtractedPage> pages;
  final PdfReadQuality quality;

  /// true 表示整本无文字层（扫描件），调用方必须拦截。
  final bool scanned;
  final int totalChars;
  final int nonEmptyPages;

  /// 疑似乱码字符占比（替换字符 / 私用区 / 控制字符）。
  final double suspiciousRatio;

  int get emptyPageCount => pageCount - nonEmptyPages;

  double get emptyPageRatio =>
      pageCount == 0 ? 1 : emptyPageCount / pageCount;

  double get averageCharsPerPage =>
      pageCount == 0 ? 0 : totalChars / pageCount;

  /// 导入前提示文案（good 返回 null）。
  String? get warningText => switch (quality) {
    PdfReadQuality.good => null,
    PdfReadQuality.mixed =>
      '检测到 $emptyPageCount/$pageCount 页没有可抽取文字（可能是扫描页混排）。'
          '这些页面会留白，其余页面可正常阅读；听书只朗读有文字的页面。',
    PdfReadQuality.unreliable =>
      '文字抽取结果疑似乱码或顺序不可靠（异常字符占比 '
          '${(suspiciousRatio * 100).toStringAsFixed(1)}%）。仍可导入阅读，'
          '但将关闭听书朗读。',
  };
}

/// 文字层质量分析（纯函数，便于单测）。
class PdfQualityAnalyzer {
  const PdfQualityAnalyzer._();

  /// 单页空白阈值：少于该字符数视为「无可抽取文字」。
  static const int emptyPageCharThreshold = 5;

  /// 异常字符占比达到该值时判为不可靠（B 级）。
  static const double suspiciousRatioThreshold = 0.03;

  /// 已知乱码特征串（编码误判时常见）。
  static const List<String> mojibakeMarkers = ['锟斤拷', '烫烫烫', '屯屯屯', 'Ã¤Â¸Â­'];

  static PdfInspection analyze({
    required String fileName,
    required String path,
    required int fileBytes,
    required int pageCount,
    required List<PdfExtractedPage> pages,
  }) {
    final totalChars = pages.fold<int>(0, (sum, page) => sum + page.text.length);
    final nonEmptyPages = pages
        .where((page) => page.text.trim().length >= emptyPageCharThreshold)
        .length;
    final emptyPageRatio = pageCount == 0
        ? 1.0
        : (pageCount - nonEmptyPages) / pageCount;
    final suspiciousRatio = _suspiciousRatio(pages);
    final joined = pages.map((page) => page.text).join('\n');
    final hasMojibake = mojibakeMarkers.any(joined.contains);

    // 1) 扫描件：整本无字，或九成以上页面无字且平均每页不足 30 字。
    final averageChars = pageCount == 0 ? 0 : totalChars / pageCount;
    final scanned =
        totalChars == 0 || (emptyPageRatio >= 0.9 && averageChars < 30);

    // 2) 不可靠：乱码特征或异常字符占比过高。
    final unreliable =
        !scanned &&
        (hasMojibake || suspiciousRatio >= suspiciousRatioThreshold);

    // 3) 混合版：部分页面无文字层（仍可阅读/朗读有字页面）。
    final quality = scanned
        ? PdfReadQuality.unreliable
        : unreliable
        ? PdfReadQuality.unreliable
        : emptyPageRatio >= 0.2
        ? PdfReadQuality.mixed
        : PdfReadQuality.good;

    return PdfInspection(
      fileName: fileName,
      path: path,
      fileBytes: fileBytes,
      pageCount: pageCount,
      pages: pages,
      quality: quality,
      scanned: scanned,
      totalChars: totalChars,
      nonEmptyPages: nonEmptyPages,
      suspiciousRatio: suspiciousRatio,
    );
  }

  static double _suspiciousRatio(List<PdfExtractedPage> pages) {
    var total = 0;
    var suspicious = 0;
    for (final page in pages) {
      for (final code in page.text.runes) {
        total++;
        if (_isSuspicious(code)) suspicious++;
      }
    }
    return total == 0 ? 0 : suspicious / total;
  }

  static bool _isSuspicious(int code) {
    if (code == 0xfffd) return true; // Unicode 替换字符
    if (code < 0x20 && code != 0x09 && code != 0x0a && code != 0x0d) {
      return true; // 控制字符（换行/制表除外）
    }
    if (code >= 0xe000 && code <= 0xf8ff) return true; // 私用区
    return false;
  }
}
