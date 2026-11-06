import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// EPUB 解析出的元数据（M9.1 用于书架展示，M9.2 首开时再由 WebView 校正）。
class EpubMeta {
  const EpubMeta({
    required this.title,
    required this.author,
    required this.chapterCount,
    this.coverBytes,
  });

  final String title;
  final String author;
  final int chapterCount;

  /// 封面图片原始字节（未缩放/压缩）；无封面或格式不支持时为 null。
  final Uint8List? coverBytes;
}

enum EpubImportError { empty, notZip, broken }

class EpubImportException implements Exception {
  const EpubImportException(this.kind, this.message);

  final EpubImportError kind;
  final String message;

  @override
  String toString() => message;
}

/// EPUB 导入（docs/reader-design.md §3.2）：zip 头校验 + OPF 元数据/章节数读取。
///
/// 书籍文件本身整本拷贝落盘，不解包改写。
class EpubImporter {
  EpubImporter._();

  /// 校验并读取元数据；[fallbackTitle] 一般取文件名（去扩展名）。
  static EpubMeta inspect(Uint8List bytes, {required String fallbackTitle}) {
    if (bytes.isEmpty) {
      throw const EpubImportException(EpubImportError.empty, '文件为空');
    }
    if (bytes.length < 4 ||
        bytes[0] != 0x50 || // P
        bytes[1] != 0x4B || // K
        bytes[2] != 0x03 ||
        bytes[3] != 0x04) {
      throw const EpubImportException(
        EpubImportError.notZip,
        '不是有效的 EPUB/ZIP 文件',
      );
    }

    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw EpubImportException(EpubImportError.broken, 'EPUB 解包失败：$e');
    }

    ArchiveFile? opf;
    for (final file in archive.files) {
      if (file.isFile && file.name.toLowerCase().endsWith('.opf')) {
        opf = file;
        break;
      }
    }
    if (opf == null) {
      throw const EpubImportException(EpubImportError.broken, '缺少 OPF 描述文件');
    }

    String xml;
    try {
      xml = utf8.decode(opf.content);
    } catch (e) {
      throw EpubImportException(EpubImportError.broken, 'OPF 解码失败：$e');
    }

    final title = _firstMatch(
          xml,
          RegExp(r'<dc:title[^>]*>([\s\S]*?)</dc:title>', caseSensitive: false),
        ) ??
        fallbackTitle;
    final author =
        _firstMatch(
          xml,
          RegExp(r'<dc:creator[^>]*>([\s\S]*?)</dc:creator>',
              caseSensitive: false),
        ) ??
        '';
    final chapterCount =
        RegExp(r'<itemref\b', caseSensitive: false).allMatches(xml).length;

    return EpubMeta(
      title: _unescapeXml(title).trim().isEmpty
          ? fallbackTitle
          : _unescapeXml(title).trim(),
      author: _unescapeXml(author).trim(),
      chapterCount: chapterCount,
      coverBytes: _coverBytes(archive, opf.name, xml),
    );
  }

  /// 只取封面字节（旧书补封面用）：任何异常都静默返回 null，不影响调用方。
  static Uint8List? readCoverQuietly(Uint8List bytes) {
    try {
      if (bytes.length < 4 ||
          bytes[0] != 0x50 ||
          bytes[1] != 0x4B ||
          bytes[2] != 0x03 ||
          bytes[3] != 0x04) {
        return null;
      }
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final file in archive.files) {
        if (!file.isFile || !file.name.toLowerCase().endsWith('.opf')) continue;
        final xml = utf8.decode(file.content);
        return _coverBytes(archive, file.name, xml);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 按 EPUB 规范找封面：EPUB3 的 `properties="cover-image"`，
  /// 兼容 EPUB2 的 `<meta name="cover" content="id">`。
  static Uint8List? _coverBytes(
    Archive archive,
    String opfPath,
    String xml,
  ) {
    final href = _coverHref(xml);
    if (href == null || href.isEmpty) return null;
    final entry = _findEntry(archive, _resolveHref(opfPath, href));
    if (entry == null) return null;
    if (_imageExts.any(entry.name.toLowerCase().endsWith)) {
      return entry.content;
    }
    // 老式 EPUB：meta cover 指向封面包装页，则取页内第一张图。
    final imageHref = _firstImageSrc(
      utf8.decode(entry.content, allowMalformed: true),
    );
    if (imageHref == null) return null;
    final imageEntry = _findEntry(
      archive,
      _resolveHref(entry.name, imageHref),
    );
    return imageEntry?.content;
  }

  static const Set<String> _imageExts = {
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.bmp',
    '.webp',
  };

  static String? _coverHref(String xml) {
    final hrefById = <String, String>{};
    String? propertyCover;
    for (final match
        in RegExp(r'<item\b[^>]*>', caseSensitive: false).allMatches(xml)) {
      final attrs = _attrs(match.group(0)!);
      final id = attrs['id'];
      final href = attrs['href'];
      if (href == null) continue;
      if (id != null) hrefById[id] = href;
      final props = attrs['properties'] ?? '';
      if (propertyCover == null &&
          props.split(RegExp(r'\s+')).contains('cover-image')) {
        propertyCover = href;
      }
    }

    String? metaCover;
    for (final match
        in RegExp(r'<meta\b[^>]*>', caseSensitive: false).allMatches(xml)) {
      final attrs = _attrs(match.group(0)!);
      if ((attrs['name'] ?? '').toLowerCase() == 'cover') {
        metaCover = attrs['content'];
        break;
      }
    }
    return propertyCover ?? hrefById[metaCover];
  }

  static Map<String, String> _attrs(String tag) {
    final result = <String, String>{};
    for (final match in RegExp(
      r'''([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
    ).allMatches(tag)) {
      result[match.group(1)!.toLowerCase()] =
          match.group(2) ?? match.group(3) ?? '';
    }
    return result;
  }

  /// 把 OPF 内相对路径（含 `../`、百分号编码）解析成 ZIP 内的完整路径。
  static String _resolveHref(String basePath, String href) {
    var ref = href.split('#').first.split('?').first;
    ref = ref.replaceAll('\\', '/');
    try {
      ref = Uri.decodeFull(ref);
    } catch (_) {
      // 非法百分号编码时按原样使用。
    }
    final segments = <String>[];
    if (basePath.contains('/')) {
      segments.addAll(basePath.substring(0, basePath.lastIndexOf('/')).split('/'));
    }
    for (final part in ref.split('/')) {
      if (part.isEmpty) continue;
      if (part == '..') {
        if (segments.isNotEmpty) segments.removeLast();
      } else if (part != '.') {
        segments.add(part);
      }
    }
    return segments.join('/');
  }

  /// ZIP 条目查找：先精确匹配，再按文件名兜底（部分 EPUB 目录层级不规范）。
  static ArchiveFile? _findEntry(Archive archive, String path) {
    final wanted = path.toLowerCase();
    for (final file in archive.files) {
      if (file.isFile && file.name.toLowerCase() == wanted) return file;
    }
    final base =
        wanted.contains('/') ? wanted.substring(wanted.lastIndexOf('/') + 1) : wanted;
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final name = file.name.toLowerCase();
      if (name == base || name.endsWith('/$base')) return file;
    }
    return null;
  }

  static String? _firstImageSrc(String html) {
    final match = RegExp(
      r'''<img\b[^>]*src\s*=\s*(?:"([^"]*)"|'([^']*)')''',
      caseSensitive: false,
    ).firstMatch(html);
    return match?.group(1) ?? match?.group(2);
  }

  static String? _firstMatch(String text, RegExp pattern) {
    final match = pattern.firstMatch(text);
    if (match == null) return null;
    return match.group(1)?.replaceAll(RegExp(r'<[^>]+>'), '') ?? '';
  }

  static String _unescapeXml(String text) => text
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}
