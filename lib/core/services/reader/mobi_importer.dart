import 'dart:convert';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:image/image.dart' as img;

import 'txt_importer.dart';

/// MOBI 解析失败原因。
enum MobiImportProblem {
  notMobi,
  tooLarge,
  encrypted,
  unsupportedCompression,
  broken,
  empty,
}

class MobiImportException implements Exception {
  const MobiImportException(this.problem, this.message);

  final MobiImportProblem problem;
  final String message;

  @override
  String toString() => message;
}

/// MOBI 解析结果：章节纯文本，可直接交给 [EpubBuilder] 打包。
class MobiImportResult {
  const MobiImportResult({
    required this.title,
    required this.author,
    required this.chapters,
    required this.encoding,
    this.coverBytes,
  });

  final String title;
  final String author;
  final List<TxtChapter> chapters;
  final String encoding;

  /// 封面原始图（JPEG/PNG 等）；没有或解析失败时为 null，由上层静默跳过。
  final Uint8List? coverBytes;
}

/// MOBI（PalmDB / PalmDOC）文本层解析 → 章节纯文本。
///
/// 与 TXT / PDF / 网页一样，解析结果在 Dart 侧打包成内部 EPUB，
/// WebView 里始终只有 foliate-js 一条渲染路径，TTS / 进度 / 备份零改动。
///
/// 支持：无压缩（1）与 PalmDOC LZ77（2）的 MOBI / AZW，UTF-8 / Windows-1252
/// 正文，EXTH 中的书名与作者。
/// 不支持：HUFF-CDIC（17480）压缩、DRM 加密、KF8 / AZW3（ZIP 容器）；
/// 这些文件会给出明确的转换提示，而不是导入成乱码。
class MobiImporter {
  MobiImporter._();

  /// 单文件上限：整本需读入内存解压，超过则拒绝以免 OOM。
  static const int maxFileBytes = 64 * 1024 * 1024;

  /// 正文上限，防止损坏文件声明超大长度撑爆内存。
  static const int maxTextBytes = 32 * 1024 * 1024;

  static MobiImportResult parse(
    Uint8List bytes, {
    required String fallbackTitle,
  }) {
    if (bytes.length > maxFileBytes) {
      throw const MobiImportException(
        MobiImportProblem.tooLarge,
        'MOBI 文件过大（上限 64 MB），请先精简或转换格式',
      );
    }
    if (bytes.length < 78 + 16) {
      throw const MobiImportException(
        MobiImportProblem.notMobi,
        '不是有效的 MOBI 文件（文件头不完整）',
      );
    }

    final pdbName = _pdbName(bytes);
    final recordCount = _u16(bytes, 76);
    if (recordCount < 2 || 78 + recordCount * 8 > bytes.length) {
      throw const MobiImportException(
        MobiImportProblem.broken,
        'MOBI 记录表损坏，无法读取正文',
      );
    }
    final offsets = <int>[];
    for (var i = 0; i < recordCount; i++) {
      offsets.add(_u32(bytes, 78 + i * 8));
    }
    final rec0 = offsets[0];
    final rec0End = offsets[1];
    if (rec0 < 78 + recordCount * 8 ||
        rec0 + 16 > bytes.length ||
        rec0End <= rec0 ||
        rec0End > bytes.length) {
      throw const MobiImportException(
        MobiImportProblem.broken,
        'MOBI 首记录损坏，无法读取正文',
      );
    }

    // 标准 MOBI 的 PDB type/creator 为 BOOK/MOBI；部分工具生成的文件只保留
    // 首记录里的 MOBI 头，两者有其一即认为格式正确。
    final bookMobi = _ascii(bytes, 60, 4) == 'BOOK' &&
        _ascii(bytes, 64, 4) == 'MOBI';
    final mobiStart = rec0 + 16;
    final hasMobiHeader =
        mobiStart + 24 <= rec0End && _ascii(bytes, mobiStart, 4) == 'MOBI';
    if (!bookMobi && !hasMobiHeader) {
      throw const MobiImportException(
        MobiImportProblem.notMobi,
        '不是有效的 MOBI 文件（缺少 BOOKMOBI 标识）',
      );
    }

    final compression = _u16(bytes, rec0);
    final textLength = _u32(bytes, rec0 + 4);
    final textRecordCount = _u16(bytes, rec0 + 8);
    final encryption = _u16(bytes, rec0 + 12);
    if (encryption != 0) {
      throw const MobiImportException(
        MobiImportProblem.encrypted,
        '该文件受 DRM 保护，暂不支持导入',
      );
    }
    if (compression == 17480) {
      throw const MobiImportException(
        MobiImportProblem.unsupportedCompression,
        '该文件使用 HUFF-CDIC 压缩，请先转换为 EPUB / TXT 再导入',
      );
    }
    if (compression != 1 && compression != 2) {
      throw MobiImportException(
        MobiImportProblem.unsupportedCompression,
        '不支持的 MOBI 压缩方式（$compression），请先转换为 EPUB / TXT',
      );
    }
    if (textLength <= 0 || textLength > maxTextBytes || textRecordCount <= 0) {
      throw const MobiImportException(
        MobiImportProblem.empty,
        '未读取到 MOBI 正文内容',
      );
    }

    var encoding = 'UTF-8';
    String? exthTitle;
    String? exthAuthor;
    int? exthCoverRecord;
    if (hasMobiHeader) {
      final mobiHeaderLength = _u32(bytes, mobiStart + 4);
      if (_u32(bytes, mobiStart + 12) == 1252) encoding = 'Windows-1252';
      // EXTH 标志位在 MOBI 头偏移 0x80，bit 6 表示后面紧跟 EXTH 头。
      final flagsOffset = mobiStart + 0x80;
      if (mobiHeaderLength > 0 &&
          flagsOffset + 4 <= rec0End &&
          (_u32(bytes, flagsOffset) & 0x40) != 0) {
        final exth = _readExth(
          bytes,
          mobiStart + mobiHeaderLength,
          rec0End,
        );
        exthTitle = exth.title;
        exthAuthor = exth.author;
        exthCoverRecord = exth.coverRecord;
      }
    }

    final text = <int>[];
    for (var i = 1; i <= textRecordCount && i < offsets.length; i++) {
      final start = offsets[i];
      final end = i + 1 < offsets.length ? offsets[i + 1] : bytes.length;
      if (start < 0 || end <= start || end > bytes.length) break;
      final record = bytes.sublist(start, end);
      text.addAll(compression == 2 ? _unpackPalmDoc(record) : record);
      if (text.length >= textLength) break;
    }
    if (text.isEmpty) {
      throw const MobiImportException(
        MobiImportProblem.empty,
        '未读取到 MOBI 正文内容',
      );
    }
    final raw = Uint8List.fromList(
      text.length > textLength ? text.sublist(0, textLength) : text,
    );
    final plain = _htmlToText(_decodeText(raw, encoding: encoding));
    if (plain.trim().isEmpty) {
      throw const MobiImportException(
        MobiImportProblem.empty,
        'MOBI 中没有可阅读的文字',
      );
    }
    final title = _firstNonEmpty([exthTitle, fallbackTitle, pdbName]);
    final chapters = TxtImporter.splitChapters(plain, fallbackTitle: title);
    if (chapters.isEmpty) {
      throw const MobiImportException(
        MobiImportProblem.empty,
        '未读取到 MOBI 正文内容',
      );
    }
    final coverBytes = _extractCover(
      bytes,
      offsets,
      exthCoverRecord,
      textRecordCount,
    );
    return MobiImportResult(
      title: title,
      author: exthAuthor?.trim() ?? '',
      chapters: chapters,
      encoding: encoding,
      coverBytes: coverBytes,
    );
  }

  /// PalmDOC LZ77 解压：字面量 / 空格二元组 / 长度-距离回溯。
  static List<int> _unpackPalmDoc(Uint8List src) {
    final out = <int>[];
    for (var i = 0; i < src.length; i++) {
      final c = src[i];
      if (c == 0) {
        out.add(0);
      } else if (c <= 8) {
        for (var j = 0; j < c && i + 1 < src.length; j++) {
          out.add(src[++i]);
        }
      } else if (c <= 0x7f) {
        out.add(c);
      } else if (c <= 0xbf) {
        if (i + 1 >= src.length) break;
        final next = src[++i];
        final distance = (((c << 8) | next) >> 3) & 0x7ff;
        final length = (next & 0x07) + 3;
        if (distance == 0 || distance > out.length) continue;
        for (var j = 0; j < length; j++) {
          out.add(out[out.length - distance]);
        }
      } else {
        // 0xC0~0xFF：一个空格 + (c ^ 0x80) 表示的字符。
        out.add(0x20);
        out.add(c & 0x7f);
      }
    }
    return out;
  }

  /// 提取 MOBI 封面：
  /// 1. 优先用 EXTH 129 给出的封面图记录下标（Kindle 标准指针，最可靠）；
  /// 2. 缺失时，在正文记录之后扫描所有图片记录，选**像素面积最大**的一张
  ///    ——封面通常是一本书里最大的图，避免误取正文内嵌的小插图。
  ///
  /// 任何一步失败都返回 null，由上层静默跳过，绝不打断导入。
  static Uint8List? _extractCover(
    Uint8List bytes,
    List<int> offsets,
    int? coverRecord,
    int textRecordCount,
  ) {
    // 1) EXTH 129 是封面权威指针，优先采用（仍需是合法图片，避免指针失效）。
    if (coverRecord != null && coverRecord > 0 && coverRecord < offsets.length) {
      final stripped = _stripImgHeader(_recordAt(bytes, offsets, coverRecord));
      if (_isImageMagic(stripped)) return stripped;
    }
    // 2) 缺失或失效时，扫全部图片记录，挑面积最大的。
    var bestArea = 0;
    Uint8List? best;
    for (var i = textRecordCount + 1; i < offsets.length; i++) {
      final stripped = _stripImgHeader(_recordAt(bytes, offsets, i));
      if (!_isImageMagic(stripped)) continue;
      final area = _imageArea(stripped);
      if (area > bestArea) {
        bestArea = area;
        best = stripped;
      }
    }
    return best;
  }

  /// 安全地取出第 [index] 条 PalmDB 记录的字节。
  static Uint8List _recordAt(Uint8List bytes, List<int> offsets, int index) {
    final start = offsets[index];
    final end = index + 1 < offsets.length ? offsets[index + 1] : bytes.length;
    if (start < 0 || end <= start || end > bytes.length) return Uint8List(0);
    return bytes.sublist(start, end);
  }

  /// 解码后返回像素面积；解码失败（非图片 / 损坏）返回 0。
  static int _imageArea(Uint8List data) {
    try {
      final image = img.decodeImage(data);
      if (image == null) return 0;
      return image.width * image.height;
    } catch (_) {
      return 0;
    }
  }

  /// 去掉 MOBI 图片记录头部的 "IMG "（12 字节）封装，得到裸 JPEG/PNG 数据。
  static Uint8List _stripImgHeader(Uint8List record) {
    if (record.length > 12 && _ascii(record, 0, 4) == 'IMG ') {
      final size = _u32(record, 8);
      if (size > 0 && size <= record.length - 12) {
        return record.sublist(12, 12 + size);
      }
      return record.sublist(12);
    }
    return record;
  }

  /// 仅做魔数判断，避免把普通记录误当封面；真正的解码 / 缩放交给 LocalBookCover。
  static bool _isImageMagic(Uint8List data) {
    if (data.isEmpty) {
      return false;
    }
    if (data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) {
      return true; // JPEG
    }
    if (data.length > 3 &&
        data[0] == 0x89 &&
        data[1] == 0x50 &&
        data[2] == 0x4E &&
        data[3] == 0x47) {
      return true; // PNG
    }
    if (data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46) {
      return true; // GIF
    }
    if (data[0] == 0x42 && data[1] == 0x4D) {
      return true; // BMP
    }
    return false;
  }

  static _Exth _readExth(Uint8List bytes, int start, int end) {
    if (start + 12 > end || _ascii(bytes, start, 4) != 'EXTH') {
      return const _Exth();
    }
    String? title;
    String? author;
    int? coverRecord;
    final count = _u32(bytes, start + 8);
    var p = start + 12;
    for (var i = 0; i < count && p + 8 <= end; i++) {
      final type = _u32(bytes, p);
      final length = _u32(bytes, p + 4);
      if (length < 8 || p + length > end) break;
      final value = bytes.sublist(p + 8, p + length);
      if (type == 503) title = _decodeExth(value);
      if (type == 100) author = _decodeExth(value);
      // 129 = 封面图记录下标；优先用它定位封面，避免误取正文内嵌图。
      if (type == 129 && length >= 12) coverRecord = _u32(value, 0);
      p += length;
    }
    return _Exth(title: title, author: author, coverRecord: coverRecord);
  }

  static String _decodeExth(Uint8List value) {
    try {
      return utf8.decode(value).trim();
    } catch (_) {
      return latin1.decode(value).trim();
    }
  }

  static String _decodeText(Uint8List bytes, {required String encoding}) {
    if (encoding == 'Windows-1252') return _decodeCp1252(bytes);
    // 正文记录末尾常带 trailing entries / 重叠字节，严格解码会整本失败；
    // 容错解码后若替换字符过多，说明文件实际是 GBK（老书常谎报 UTF-8）。
    final text = utf8.decode(bytes, allowMalformed: true);
    final bad = '\uFFFD'.allMatches(text).length;
    if (bad > 0 && bad * 20 > text.length) {
      try {
        return gbk.decode(bytes);
      } catch (_) {
        return latin1.decode(bytes);
      }
    }
    return text;
  }

  static const Map<int, int> _cp1252 = {
    0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E,
    0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6,
    0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152,
    0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201C,
    0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
    0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A,
    0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178,
  };

  static String _decodeCp1252(Uint8List bytes) =>
      String.fromCharCodes(bytes.map((b) => _cp1252[b] ?? b));

  /// MOBI 正文是老式 HTML（含 mbp:pagebreak / filepos 等私有标签）：
  /// 块级标签转空行以保留段落边界，其余标签剥离，再交给 TXT 清洗与切章。
  static String _htmlToText(String html) {
    var s = html;
    final body = RegExp(
      r'<body\b[^>]*>',
      caseSensitive: false,
    ).firstMatch(s);
    if (body != null) s = s.substring(body.end);
    s = s.replaceAll(
      RegExp(
        r'<(script|style)\b[^>]*>.*?</\1>',
        caseSensitive: false,
        dotAll: true,
      ),
      '',
    );
    s = s.replaceAll(
      RegExp(
        r'<\s*/?\s*(?:p|div|br|h[1-6]|li|tr|blockquote|hr|mbp:pagebreak)\b[^>]*>',
        caseSensitive: false,
      ),
      '\n\n',
    );
    s = s.replaceAll(RegExp(r'<[^>]*>'), '');
    s = _decodeEntities(s);
    // 去掉解压残留的尾部控制字节与 UTF-8 替换符，避免正文出现乱码方块。
    s = s.replaceAll('\uFFFD', '');
    s = s.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');
    return TxtImporter.clean(s);
  }

  static String _decodeEntities(String value) {
    const named = {
      'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'",
      'nbsp': ' ', 'mdash': '—', 'ndash': '–', 'hellip': '…',
      'ldquo': '“', 'rdquo': '”', 'lsquo': '‘', 'rsquo': '’',
    };
    return value.replaceAllMapped(
      RegExp(r'&(#x?[0-9A-Fa-f]+|[A-Za-z]+);'),
      (match) {
        final body = match.group(1)!;
        if (body.startsWith('#')) {
          final hex = body.startsWith('#x') || body.startsWith('#X');
          final digits = hex ? body.substring(2) : body.substring(1);
          final code = int.tryParse(digits, radix: hex ? 16 : 10);
          return code == null ? match.group(0)! : String.fromCharCode(code);
        }
        return named[body.toLowerCase()] ?? match.group(0)!;
      },
    );
  }

  static String _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      final trimmed = value?.trim() ?? '';
      if (trimmed.isNotEmpty) return trimmed;
    }
    return '未命名书籍';
  }

  static String _pdbName(Uint8List bytes) {
    var length = 32;
    for (var i = 0; i < 32; i++) {
      if (bytes[i] == 0) {
        length = i;
        break;
      }
    }
    return _ascii(bytes, 0, length);
  }

  static String _ascii(Uint8List bytes, int offset, int length) {
    if (offset < 0 || length <= 0 || offset + length > bytes.length) return '';
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      final c = bytes[offset + i];
      if (c < 0x20 || c > 0x7e) return '';
      buffer.writeCharCode(c);
    }
    return buffer.toString();
  }

  static int _u16(Uint8List bytes, int offset) {
    if (offset < 0 || offset + 2 > bytes.length) return 0;
    return (bytes[offset] << 8) | bytes[offset + 1];
  }

  static int _u32(Uint8List bytes, int offset) {
    if (offset < 0 || offset + 4 > bytes.length) return 0;
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }
}

class _Exth {
  const _Exth({this.title, this.author, this.coverRecord});

  final String? title;
  final String? author;

  /// EXTH 129 给出的封面图记录下标；为 null 时走图片记录回退扫描。
  final int? coverRecord;
}
