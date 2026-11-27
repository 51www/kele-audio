import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'epub_importer.dart';

/// 离线章节正文源：WebView 冻结/关闭时的兜底段落来源（息屏跨章续读）。
abstract class TtsChapterTextSource {
  /// 取第 [chapterIndex] 章（0 基）的正文段落，口径与阅读页 WebView 抽取一致
  /// （assets/reader/index.html 的 extractChapter / textOf）。
  ///
  /// 章节越界或本章无正文返回空列表；源不可读（文件缺失/解包失败）抛异常，
  /// 调用方据此区分「真空章」与「取不到正文」，绝不能把后者当空章连跳。
  Future<List<String>> paragraphsOf(String bookId, int chapterIndex);
}

/// 直接解 `book.epub` 的 zip 抽取章节段落，不经过 WebView。
///
/// 阅读页 WebView 在锁屏/息屏期间会被冻结（章节抽取 10s 超时或直接挂死），
/// 跨章续读若只依赖 WebView 就会在章边界停住。本类按 OPF spine 章序离线取段，
/// 让朗读在息屏状态下也能继续。
class EpubChapterText implements TtsChapterTextSource {
  EpubChapterText({
    required Future<Uint8List?> Function(String bookId) loadBytes,
  }) : _loadBytes = loadBytes;

  final Future<Uint8List?> Function(String bookId) _loadBytes;

  /// 单书缓存：朗读一次会话只用一本书，避免每章重复解包。
  String? _cacheBookId;
  _ParsedEpub? _cache;

  @override
  Future<List<String>> paragraphsOf(String bookId, int chapterIndex) async {
    final parsed = await _ensureParsed(bookId);
    if (chapterIndex < 0 || chapterIndex >= parsed.chapterPaths.length) {
      return const [];
    }
    final entry = EpubImporter.findEntry(
      parsed.archive,
      parsed.chapterPaths[chapterIndex],
    );
    if (entry == null) return const [];
    final html = utf8.decode(entry.content, allowMalformed: true);
    return extractParagraphsFromXhtml(html);
  }

  Future<_ParsedEpub> _ensureParsed(String bookId) async {
    final cached = _cache;
    if (cached != null && _cacheBookId == bookId) return cached;
    final bytes = await _loadBytes(bookId);
    if (bytes == null || bytes.isEmpty) {
      throw StateError('书籍文件缺失：$bookId');
    }
    final parsed = _parse(bytes);
    _cacheBookId = bookId;
    _cache = parsed;
    return parsed;
  }

  /// 解析 EPUB：manifest/spine → 章节 zip 路径（spine 顺序 = 章序，
  /// 与导入时的 chapterCount（itemref 数）以及 foliate 的 section 序一致）。
  static _ParsedEpub _parse(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    ArchiveFile? opf;
    for (final file in archive.files) {
      if (file.isFile && file.name.toLowerCase().endsWith('.opf')) {
        opf = file;
        break;
      }
    }
    if (opf == null) throw const FormatException('EPUB 缺少 OPF 描述文件');
    final xml = utf8.decode(opf.content, allowMalformed: true);

    final hrefById = <String, String>{};
    for (final match
        in RegExp(r'<item\b[^>]*>', caseSensitive: false).allMatches(xml)) {
      final attrs = EpubImporter.parseAttrs(match.group(0)!);
      final id = attrs['id'];
      final href = attrs['href'];
      if (id != null && href != null) hrefById[id] = href;
    }
    final chapterPaths = <String>[];
    for (final match
        in RegExp(r'<itemref\b[^>]*>', caseSensitive: false).allMatches(xml)) {
      final attrs = EpubImporter.parseAttrs(match.group(0)!);
      final href = hrefById[attrs['idref']];
      if (href == null) continue;
      chapterPaths.add(EpubImporter.resolveHref(opf.name, href));
    }
    return _ParsedEpub(archive, chapterPaths);
  }

  /// XHTML 正文 → 段落纯文本，口径对齐 assets/reader/index.html 的 extractChapter：
  /// 跳过 script/style/nav；只取无块级祖先的最外层块（避免 li>p 重复）；
  /// textOf 归一（块边界/`<br>` 计空格、合并空白、trim）；长度 < 2 丢弃。
  static List<String> extractParagraphsFromXhtml(String html) {
    var text = html;
    text = text.replaceAll(
      RegExp(r'<!--[\s\S]*?-->', caseSensitive: false),
      ' ',
    );
    text = text.replaceAllMapped(
      RegExp(
        r'<(script|style|nav)\b[^>]*>[\s\S]*?</\1\s*>',
        caseSensitive: false,
      ),
      (_) => ' ',
    );
    final blocks = <_BlockSpan>[];
    final blockRe = RegExp(
      r'<(p|li|blockquote|dd|dt|h1|h2|h3|h4|h5|h6)\b[^>]*>([\s\S]*?)</\1\s*>',
      caseSensitive: false,
    );
    for (final match in blockRe.allMatches(text)) {
      blocks.add(_BlockSpan(match.start, match.end, match.group(2)!));
    }
    final result = <String>[];
    for (final block in blocks) {
      // 只保留最外层块：被其它块完整包住的丢弃（JS 端同款跳过规则）。
      final nested = blocks.any(
        (other) =>
            !identical(other, block) &&
            other.start <= block.start &&
            block.end <= other.end,
      );
      if (nested) continue;
      final plain = _plainText(block.inner);
      if (plain.length < 2) continue;
      result.add(plain);
    }
    return result;
  }

  static String _plainText(String inner) {
    var text = inner.replaceAllMapped(
      RegExp(r'</?([a-zA-Z][\w:-]*)\b[^>]*>', caseSensitive: false),
      (match) =>
          _breakTags.contains(match.group(1)!.toLowerCase()) ? ' ' : '',
    );
    // 块级替换后残留的标签（DOCTYPE 等）直接去掉，字面 `<` 不会命中这里。
    text = text.replaceAll(RegExp(r'<[^>]+>'), '');
    text = _decodeEntities(text);
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// 块级标签在 innerText 里折行，归一后等价于一个空格；行内标签直接去掉。
  static const Set<String> _breakTags = {
    'p', 'div', 'li', 'ul', 'ol', 'table', 'tr', 'td', 'th', 'blockquote',
    'dd', 'dt', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'section', 'article',
    'header', 'footer', 'pre', 'hr', 'br', 'figure', 'figcaption',
    'address', 'dir', 'menu', 'dl',
  };

  static String _decodeEntities(String text) {
    return text.replaceAllMapped(
      RegExp(r'&(#[xX]?[0-9a-fA-F]+|[a-zA-Z]+);'),
      (match) {
        final token = match.group(1)!;
        if (token.startsWith('#')) {
          final hex = token[1] == 'x' || token[1] == 'X';
          final code = int.tryParse(
            hex ? token.substring(2) : token.substring(1),
            radix: hex ? 16 : 10,
          );
          if (code == null || code <= 0 || code > 0x10FFFF) return match.group(0)!;
          return String.fromCharCodes([code]);
        }
        return _namedEntities[token.toLowerCase()] ?? match.group(0)!;
      },
    );
  }

  static const Map<String, String> _namedEntities = {
    'amp': '&',
    'lt': '<',
    'gt': '>',
    'quot': '"',
    'apos': "'",
    'nbsp': '\u00A0',
    'ensp': '\u2002',
    'emsp': '\u2003',
    'thinsp': '\u2009',
    'mdash': '—',
    'ndash': '–',
    'hellip': '…',
    'ldquo': '“',
    'rdquo': '”',
    'lsquo': '‘',
    'rsquo': '’',
    'laquo': '«',
    'raquo': '»',
    'copy': '©',
    'reg': '®',
    'trade': '™',
    'times': '×',
    'middot': '·',
    'bull': '•',
    'deg': '°',
    'plusmn': '±',
    'minus': '−',
    'sect': '§',
    'para': '¶',
  };
}

class _ParsedEpub {
  const _ParsedEpub(this.archive, this.chapterPaths);

  final Archive archive;
  final List<String> chapterPaths;
}

class _BlockSpan {
  const _BlockSpan(this.start, this.end, this.inner);

  final int start;
  final int end;
  final String inner;
}
