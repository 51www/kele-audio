import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// EPUB 解析出的元数据（M9.1 用于书架展示，M9.2 首开时再由 WebView 校正）。
class EpubMeta {
  const EpubMeta({
    required this.title,
    required this.author,
    required this.chapterCount,
  });

  final String title;
  final String author;
  final int chapterCount;
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
    );
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
