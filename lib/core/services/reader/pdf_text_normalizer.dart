import 'dart:math' as math;

/// PDF 抽取文本的清洗与段落化（M10.1）。
///
/// 目标：把 PDFium 按行输出的文本还原成「段落」，避免整章被 TTS 当成
/// 一段连续朗读。清洗项：
/// - 跨页重复的页眉/页脚（含带页码的页脚，按数字归一后统计频次）；
/// - 单独成行的页码；
/// - 行尾连字符断词（英文）；
/// - 跨页被截断的段落（上一页末尾无句末标点则与下一页首行合并）。
///
/// 输出为 `List<String>`，每个元素是一个完整段落；导入时逐段生成
/// `<p>`，保证 TTS 按段落切分。
class PdfTextNormalizer {
  const PdfTextNormalizer._();

  /// 页码形态（整行）：`- 3 -`、`第 3 页`、`3 / 10`、`3` 等。
  static final RegExp _pageNumberLine = RegExp(
    r'^(?:[-—–]\s*)?(?:第\s*)?\d+(?:\s*(?:页|/\s*\d+))?\s*(?:页)?(?:\s*[-—–])?$',
  );

  /// 列表/编号开头，遇到即视为新段落。
  static final RegExp _listStart = RegExp(
    r'^(?:[•·▪◦]\s*|[（(]?\d{1,3}[.、)）]\s*|第[一二三四五六七八九十百千]+[章节条款])',
  );

  /// 句末标点（含中文引号收尾）。
  static const String _sentenceEnd = '。！？；：…』」》〕】)”’"';

  /// 英文句末标点。
  static const String _latinSentenceEnd = '.!?;:';

  /// 运行页眉/页脚的最小重复次数。
  static const int _minRepeat = 3;

  /// 运行页眉/页脚占页数的最低比例。
  static const double _minRepeatRatio = 0.3;

  /// 把逐页文本清洗为段落列表。
  static List<String> paragraphsFromPages(List<String> pageTexts) {
    if (pageTexts.isEmpty) return const [];

    final pages = [
      for (final text in pageTexts) _linesOf(text),
    ];
    final rejected = <String>{};
    if (pages.length >= _minRepeat) {
      rejected.addAll(_repeatedEdgeLines(pages));
    }

    final paragraphs = <String>[];
    final buffer = StringBuffer();

    void flush() {
      final text = _finishParagraph(buffer.toString());
      buffer.clear();
      if (text.isEmpty) return;
      if (paragraphs.isNotEmpty && paragraphs.last == text) return;
      paragraphs.add(text);
    }

    for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
      final lines = pages[pageIndex];
      final edgeIndexes = _edgeIndexes(lines.length);
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) {
          flush();
          continue;
        }
        final isEdge = edgeIndexes.contains(i);
        if (isEdge && _pageNumberLine.hasMatch(line)) continue;
        if (isEdge && rejected.contains(_signature(line))) continue;
        if (_pageNumberLine.hasMatch(line)) {
          flush();
          continue;
        }
        if (_listStart.hasMatch(line)) flush();

        final endsSentence = buffer.isNotEmpty && _endsSentence(buffer.toString());
        if (endsSentence) flush();

        _appendLine(buffer, line);
      }

      // 页边界：上一页最后一段没有句末标点 → 与下一页首行合并（跨页续段）。
      if (buffer.isNotEmpty && _endsSentence(buffer.toString())) flush();
      // 页面之间留一个段落边界，避免把上一页的行首直接粘到下一页。
      if (pageIndex + 1 < pages.length &&
          buffer.isNotEmpty &&
          !_endsSentence(buffer.toString())) {
        // 保留 buffer，等待下一页继续；但若下一页首行是页眉/页码，会先被跳过。
        continue;
      }
    }
    flush();
    return paragraphs;
  }

  /// 逐段生成 `<p>`（调用方传入 HTML 转义函数，避免重复实现）。
  static String paragraphsToHtml(
    List<String> paragraphs,
    String Function(String) escape,
  ) => paragraphs
      .where((p) => p.trim().isNotEmpty)
      .map((p) => '<p>${escape(p)}</p>')
      .join();

  static List<String> _linesOf(String text) {
    final normalized = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\u00a0', ' ')
        .replaceAll('\u3000', ' ');
    return normalized.split('\n');
  }

  /// 归一化后的行签名：数字→`#`，压缩空白，便于统计重复页眉/页脚。
  static String _signature(String line) => line
      .replaceAll(RegExp(r'\d+'), '#')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static Set<int> _edgeIndexes(int length) {
    if (length <= 0) return const {};
    if (length <= 3) return {for (var i = 0; i < length; i++) i};
    return {0, 1, length - 2, length - 1};
  }

  /// 统计出现在多数页面首/尾的重复行（页眉、页脚）。
  static Set<String> _repeatedEdgeLines(List<List<String>> pages) {
    final counts = <String, int>{};
    for (final lines in pages) {
      final signature = <String>{};
      final edge = _edgeIndexes(lines.length);
      for (final index in edge) {
        if (index >= lines.length) continue;
        final line = lines[index].trim();
        if (line.isEmpty || line.length > 40) continue;
        signature.add(_signature(line));
      }
      for (final sig in signature) {
        counts[sig] = (counts[sig] ?? 0) + 1;
      }
    }
    final threshold = math.max(_minRepeat, (pages.length * _minRepeatRatio).ceil());
    return {
      for (final entry in counts.entries)
        if (entry.value >= threshold) entry.key,
    };
  }

  static bool _endsSentence(String text) {
    final trimmed = text.trimRight();
    if (trimmed.isEmpty) return true;
    final last = trimmed.codeUnitAt(trimmed.length - 1);
    final char = String.fromCharCode(last);
    return _sentenceEnd.contains(char) ||
        _latinSentenceEnd.contains(char) ||
        char == '!';
  }

  static void _appendLine(StringBuffer buffer, String line) {
    if (buffer.isEmpty) {
      buffer.write(line);
      return;
    }
    final left = buffer.toString().trimRight();
    final right = line.trimLeft();
    // 英文断词连字符：`inter-` + `national` → `international`。
    if (left.endsWith('-') &&
        right.isNotEmpty &&
        _isLatinLetter(right.codeUnitAt(0))) {
      buffer.write(right);
      return;
    }
    final lastCode = left.isEmpty ? 0 : left.codeUnitAt(left.length - 1);
    final firstCode = right.isEmpty ? 0 : right.codeUnitAt(0);
    final needsSpace = _isLatinWordChar(lastCode) && _isLatinWordChar(firstCode);
    if (needsSpace) buffer.write(' ');
    buffer.write(right);
  }

  static bool _isLatinLetter(int code) =>
      (code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a);

  static bool _isLatinWordChar(int code) =>
      _isLatinLetter(code) || (code >= 0x30 && code <= 0x39);

  static String _finishParagraph(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'[\u0000-\u0008\u000b\u000c\u000e-\u001f]'), '')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .trim();
    return cleaned;
  }
}

/// 本地拆分实现（避免为一行逻辑额外引入依赖）。
class LineSplitter {
  const LineSplitter();

  List<String> convert(String input) => input.split('\n');
}
