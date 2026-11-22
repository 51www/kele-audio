import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 内部 EPUB 的一章。[html] 为 body 内的 XHTML 片段。
class EpubChapter {
  const EpubChapter({required this.title, required this.html});

  final String title;
  final String html;
}

/// 轻量 EPUB 打包（docs/reader-design.md §3.1.4 / §4）。
///
/// TXT 与网页正文都在 Dart 侧转成章节 XHTML 后打包成 EPUB，
/// WebView 内只有 foliate-js 一条渲染路径，TTS 也只取文本。
class EpubBuilder {
  EpubBuilder._();

  static const String _defaultCss = '''
body { margin: 0; padding: 16px; font-family: serif; line-height: 1.8;
       word-break: break-word; color: #222; }
h2 { font-size: 1.15em; margin: 0 0 0.8em; }
p { margin: 0 0 0.8em; text-indent: 2em; }
img { max-width: 100%; height: auto; }
''';

  /// 打包 EPUB（EPUB 3，附带 NCX 兼容旧阅读器）。
  static Uint8List build({
    required String title,
    String author = '',
    required List<EpubChapter> chapters,
    String language = 'zh-CN',
  }) {
    final safeChapters = chapters.isEmpty
        ? const [EpubChapter(title: '正文', html: '<p>（无内容）</p>')]
        : chapters;
    final uid =
        'urn:uuid:${DateTime.now().microsecondsSinceEpoch.toString().padLeft(16, '0')}';
    final safeTitle = _escapeXml(title.isEmpty ? '未命名' : title);
    final safeAuthor = _escapeXml(author);

    final archive = Archive();

    // mimetype 必须是第一个条目且不压缩。
    final mimetype = ArchiveFile.bytes(
      'mimetype',
      utf8.encode('application/epub+zip'),
    )..compression = CompressionType.none;
    archive.add(mimetype);

    archive.add(ArchiveFile.string(
      'META-INF/container.xml',
      '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''',
    ));

    final chapterFiles = <String>[];
    for (var i = 0; i < safeChapters.length; i++) {
      final chapter = safeChapters[i];
      final href = 'chapter${i + 1}.xhtml';
      chapterFiles.add(href);
      archive.add(ArchiveFile.string(
        'OEBPS/$href',
        _chapterXhtml(
          title: chapter.title,
          html: sanitizeHtml(chapter.html),
        ),
      ));
    }

    final manifest = StringBuffer();
    final spine = StringBuffer();
    final navPoints = StringBuffer();
    for (var i = 0; i < chapterFiles.length; i++) {
      final id = 'c${i + 1}';
      manifest.writeln(
        '    <item id="$id" href="${chapterFiles[i]}" '
        'media-type="application/xhtml+xml"/>',
      );
      spine.writeln('    <itemref idref="$id"/>');
      navPoints.writeln(
        '    <navPoint id="navPoint-${i + 1}" playOrder="${i + 1}">'
        '<navLabel><text>${_escapeXml(safeChapters[i].title)}</text></navLabel>'
        '<content src="${chapterFiles[i]}"/></navPoint>',
      );
    }

    final navItems = StringBuffer();
    for (var i = 0; i < chapterFiles.length; i++) {
      navItems.writeln(
        '      <li><a href="${chapterFiles[i]}">'
        '${_escapeXml(safeChapters[i].title)}</a></li>',
      );
    }

    archive.add(ArchiveFile.string(
      'OEBPS/content.opf',
      '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">$uid</dc:identifier>
    <dc:title>$safeTitle</dc:title>
    <dc:creator>$safeAuthor</dc:creator>
    <dc:language>$language</dc:language>
    <meta property="dcterms:modified">${_nowIso()}</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
$manifest  </manifest>
  <spine toc="ncx">
$spine  </spine>
</package>
''',
    ));

    archive.add(ArchiveFile.string(
      'OEBPS/nav.xhtml',
      '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="$language">
<head><meta charset="utf-8"/><title>$safeTitle</title></head>
<body>
  <nav epub:type="toc" id="toc">
    <h1>目录</h1>
    <ol>
$navItems    </ol>
  </nav>
</body>
</html>
''',
    ));

    archive.add(ArchiveFile.string(
      'OEBPS/toc.ncx',
      '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="$uid"/></head>
  <docTitle><text>$safeTitle</text></docTitle>
  <navMap>
$navPoints  </navMap>
</ncx>
''',
    ));

    final encoded = ZipEncoder().encode(
      archive,
      level: DeflateLevel.defaultCompression,
    );
    return Uint8List.fromList(encoded);
  }

  /// 纯文本 → XHTML 段落。空行分段，其余换行视为段落内换行。
  static String textToHtml(String text) {
    final paragraphs = text
        .split(RegExp(r'\n\s*\n'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty);
    return paragraphs
        .map((p) => '<p>${_escapeXml(p).replaceAll('\n', '<br/>')}</p>')
        .join('\n');
  }

  /// 去掉脚本/样式与内联事件，避免导入内容在阅读 WebView 内执行代码。
  static String sanitizeHtml(String html) {
    var result = html.replaceAll(
      RegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
      '',
    );
    result = result.replaceAll(
      RegExp(r'<style[\s\S]*?</style>', caseSensitive: false),
      '',
    );
    result = result.replaceAll(
      RegExp(r'''\son\w+\s*=\s*"[^"]*"''', caseSensitive: false),
      '',
    );
    result = result.replaceAll(
      RegExp(r"""\son\w+\s*=\s*'[^']*'""", caseSensitive: false),
      '',
    );
    return result;
  }

  static String _chapterXhtml({required String title, required String html}) {
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN">
<head>
  <meta charset="utf-8"/>
  <title>${_escapeXml(title)}</title>
  <style>$_defaultCss</style>
</head>
<body>
<h2>${_escapeXml(title)}</h2>
$html
</body>
</html>
''';
  }

  static String _escapeXml(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  static String _nowIso() {
    final now = DateTime.now().toUtc();
    final year = now.year.toString().padLeft(4, '0');
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    final second = now.second.toString().padLeft(2, '0');
    return '$year-$month-${day}T$hour:$minute:${second}Z';
  }

  /// 生成书籍 id（时间戳 + 随机后缀）。
  static String newBookId() {
    final rand = Random().nextInt(0x7fffffff).toRadixString(36);
    return '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}$rand';
  }
}
