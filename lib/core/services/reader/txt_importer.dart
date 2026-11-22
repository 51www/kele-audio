import 'dart:convert';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';

/// 切分后的章节（标题 + 正文纯文本）。
class TxtChapter {
  const TxtChapter({required this.title, required this.content});

  final String title;
  final String content;
}

/// TXT 导入结果。
class TxtImportResult {
  const TxtImportResult({
    required this.title,
    required this.encoding,
    required this.chapters,
    required this.charCount,
  });

  final String title;

  /// 识别出的编码（UTF-8 / GBK / UTF-16LE / UTF-16BE / Latin-1）。
  final String encoding;
  final List<TxtChapter> chapters;
  final int charCount;
}

/// TXT 导入（docs/reader-design.md §3.1）：
/// 编码识别（BOM / UTF-8 严格 / GBK 回退）→ 清洗 → 章节切分。
class TxtImporter {
  TxtImporter._();

  /// 无章节标题时的兜底每章字数。
  static const int fallbackChapterChars = 5000;

  /// 解析 TXT 字节。[fallbackTitle] 一般取文件名（去扩展名）。
  static TxtImportResult parse(
    Uint8List bytes, {
    required String fallbackTitle,
  }) {
    final decoded = _decode(bytes);
    final cleaned = clean(decoded.text);
    final chapters = splitChapters(cleaned, fallbackTitle: fallbackTitle);
    return TxtImportResult(
      title: fallbackTitle,
      encoding: decoded.encoding,
      chapters: chapters,
      charCount: cleaned.length,
    );
  }

  /// 编码识别：BOM 优先；否则 UTF-8 严格解码，失败回退 GBK，再失败按 Latin-1。
  static _DecodedText _decode(Uint8List bytes) {
    if (bytes.isEmpty) return const _DecodedText('', 'UTF-8');

    // UTF-8 BOM
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return _DecodedText(utf8.decode(bytes.sublist(3)), 'UTF-8');
    }
    // UTF-16 LE / BE BOM
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _DecodedText(_decodeUtf16(bytes.sublist(2), littleEndian: true),
          'UTF-16LE');
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _DecodedText(_decodeUtf16(bytes.sublist(2), littleEndian: false),
          'UTF-16BE');
    }

    try {
      return _DecodedText(utf8.decode(bytes), 'UTF-8');
    } on FormatException {
      // 继续尝试 GBK
    }

    try {
      return _DecodedText(gbk.decode(bytes), 'GBK');
    } catch (_) {
      return _DecodedText(latin1.decode(bytes), 'Latin-1');
    }
  }

  static String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add(littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }

  /// 清洗：统一换行、去 BOM、去行尾空白、连续空行归一为一个空行。
  static String clean(String text) {
    final normalized = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\uFEFF', '');
    final lines = normalized.split('\n');
    final out = <String>[];
    var blank = 0;
    for (final line in lines) {
      final trimmed = line.trimRight();
      if (trimmed.trim().isEmpty) {
        blank++;
        continue;
      }
      if (blank > 0 && out.isNotEmpty) out.add('');
      blank = 0;
      out.add(trimmed);
    }
    return out.join('\n').trim();
  }

  static final List<RegExp> _headingPatterns = [
    RegExp(r'^第[0-9零〇一二三四五六七八九十百千万两]+[章卷节回部集篇][^\n]{0,40}$'),
    RegExp(r'^Chapter\s+[0-9]+[^\n]{0,40}$', caseSensitive: false),
    RegExp(r'^(序章|楔子|前言|序言|后记|尾声|番外)[^\n]{0,30}$'),
    RegExp(r'^[（(【\[]?[0-9]{1,4}[）)】\]]?[、.．]\s?[^\n]{1,30}$'),
  ];

  /// 章节切分：标题行命中数 ≥ 3 时按标题切；否则按字数兜底。
  static List<TxtChapter> splitChapters(
    String text, {
    String fallbackTitle = '正文',
  }) {
    if (text.trim().isEmpty) return const [];
    final chapters = _splitByHeadings(text);
    if (chapters.length >= 3) return chapters;
    return _splitByLength(text, fallbackTitle: fallbackTitle);
  }

  static List<TxtChapter> _splitByHeadings(String text) {
    final lines = text.split('\n');
    final chapters = <TxtChapter>[];
    String? title;
    final buffer = StringBuffer();

    void flush() {
      final content = buffer.toString().trim();
      if (title != null && content.isNotEmpty) {
        chapters.add(TxtChapter(title: title, content: content));
      }
      buffer.clear();
    }

    for (final line in lines) {
      final candidate = line.trim();
      if (candidate.isNotEmpty && _isHeading(candidate)) {
        flush();
        title = candidate;
      } else {
        buffer.writeln(line);
      }
    }
    flush();
    return chapters;
  }

  static bool _isHeading(String line) {
    if (line.length > 50) return false;
    for (final pattern in _headingPatterns) {
      if (pattern.hasMatch(line)) return true;
    }
    return false;
  }

  static List<TxtChapter> _splitByLength(
    String text, {
    required String fallbackTitle,
  }) {
    final paragraphs = text
        .split(RegExp(r'\n\s*\n'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (paragraphs.isEmpty) {
      return [TxtChapter(title: fallbackTitle, content: text.trim())];
    }

    final chapters = <TxtChapter>[];
    final buffer = StringBuffer();
    var length = 0;

    void flush() {
      final content = buffer.toString().trim();
      if (content.isEmpty) return;
      chapters.add(
        TxtChapter(title: '第${chapters.length + 1}章', content: content),
      );
      buffer.clear();
      length = 0;
    }

    for (final paragraph in paragraphs) {
      // 单段就超长时独占一章，避免把一段拆碎。
      if (paragraph.length >= fallbackChapterChars) {
        flush();
        chapters.add(
          TxtChapter(title: '第${chapters.length + 1}章', content: paragraph),
        );
        continue;
      }
      if (length + paragraph.length > fallbackChapterChars) flush();
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer.write(paragraph);
      length += paragraph.length;
    }
    flush();

    // 只有一个兜底章节时，用文件名做标题更直观。
    if (chapters.length == 1) {
      return [TxtChapter(title: fallbackTitle, content: chapters.first.content)];
    }
    return chapters;
  }
}

class _DecodedText {
  const _DecodedText(this.text, this.encoding);

  final String text;
  final String encoding;
}
