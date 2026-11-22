import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:kele_audio/core/api/key_value_store.dart';
import 'package:kele_audio/core/domain/reader_book.dart';
import 'package:kele_audio/core/services/reader/book_store.dart';
import 'package:kele_audio/core/services/reader/epub_importer.dart';
import 'package:kele_audio/core/services/reader/mobi_importer.dart';
import 'package:kele_audio/core/services/reader/reader_activity_store.dart';
import 'package:kele_audio/core/services/reader/reader_import_service.dart';
import 'package:kele_audio/core/services/reader/txt_to_epub.dart';
import 'package:kele_audio/features/shelf/shelf_tab.dart';

const String _sampleHtml = '<html><head><title>不该出现</title></head><body>'
    '<h1>第一章 初入江湖</h1><p>桥头下着雨 &amp; 风很大。</p>'
    '<mbp:pagebreak/><h1>第二章 夜行</h1><p>他走进巷子，脚步很轻。</p>'
    '<h1>第三章 天亮</h1><p>远处传来钟声。</p></body></html>';

void main() {
  test('无压缩 MOBI：EXTH 元数据 + HTML 清洗 + 章节切分', () {
    final result = MobiImporter.parse(
      _sampleMobi(
        text: Uint8List.fromList(utf8.encode(_sampleHtml)),
        exthTitle: '江湖夜雨',
        exthAuthor: '测试作者',
      ),
      fallbackTitle: '江湖夜雨',
    );

    expect(result.title, '江湖夜雨');
    expect(result.author, '测试作者');
    expect(result.encoding, 'UTF-8');
    expect(result.chapters.length, 3);
    expect(result.chapters.first.title, '第一章 初入江湖');
    expect(result.chapters.first.content, contains('桥头下着雨 & 风很大'));
    expect(result.chapters.first.content, isNot(contains('<p>')));
    expect(result.chapters.first.content, isNot(contains('不该出现')));
  });

  test('PalmDOC LZ77 压缩的 MOBI 可正常解压导入', () {
    final text = Uint8List.fromList(utf8.encode(_sampleHtml));
    final result = MobiImporter.parse(
      _sampleMobi(
        text: _palmdocLiterals(text),
        compression: 2,
        declaredLength: text.length,
        exthTitle: '压缩样书',
      ),
      fallbackTitle: '压缩样书',
    );
    expect(result.title, '压缩样书');
    expect(result.chapters.length, 3);
    expect(result.chapters.last.content, contains('远处传来钟声'));
  });

  test('PalmDOC 长度-距离回溯按重叠窗口还原', () {
    // 字面量 abc + 回溯（distance=3, length=10）。
    final compressed = Uint8List.fromList([3, 97, 98, 99, 0x80, 0x1F]);
    final result = MobiImporter.parse(
      _sampleMobi(
        text: compressed,
        compression: 2,
        declaredLength: 13,
      ),
      fallbackTitle: '回溯样本',
    );
    expect(result.chapters.single.content, 'abcabcabcabca');
  });

  test('无 EXTH 时回退文件名，Windows-1252 正文可解码', () {
    final text = latin1.encode('<body><p>Caf\u00e9 &amp; th\u00e9.</p></body>');
    final result = MobiImporter.parse(
      _sampleMobi(
        text: Uint8List.fromList(text),
        encoding: 1252,
      ),
      fallbackTitle: '咖啡馆',
    );
    expect(result.title, '咖啡馆');
    expect(result.encoding, 'Windows-1252');
    expect(result.chapters.single.content, contains('Café & thé.'));
  });

  test('非 MOBI / 加密 / HUFF-CDIC / 空正文给出明确错误', () {
    final text = Uint8List.fromList(utf8.encode(_sampleHtml));

    MobiImportProblem problemOf(Uint8List bytes) {
      try {
        MobiImporter.parse(bytes, fallbackTitle: 'x');
      } on MobiImportException catch (e) {
        return e.problem;
      }
      return MobiImportProblem.broken;
    }

    expect(
      problemOf(_sampleMobi(
        text: text,
        type: 'TEXt',
        creator: 'REAd',
        mobiHeader: false,
      )),
      MobiImportProblem.notMobi,
    );
    expect(
      problemOf(_sampleMobi(text: text, encryption: 2)),
      MobiImportProblem.encrypted,
    );
    expect(
      problemOf(_sampleMobi(text: text, compression: 17480)),
      MobiImportProblem.unsupportedCompression,
    );
    expect(
      problemOf(_sampleMobi(text: Uint8List(0), declaredLength: 0)),
      MobiImportProblem.empty,
    );
    expect(
      () => MobiImporter.parse(
        Uint8List.fromList(utf8.encode('not a mobi')),
        fallbackTitle: 'x',
      ),
      throwsA(isA<MobiImportException>()),
    );
  });

  test('正文尾部脏字节不会让整本中文回退成乱码', () {
    final clean = utf8.encode('<body><p>桥头下着雨 &amp; 风很大，他走进巷子。</p></body>');
    final dirty = Uint8List.fromList([...clean, 0xFF, 0xFE, 0x00]);
    final result = MobiImporter.parse(
      _sampleMobi(text: dirty, declaredLength: dirty.length),
      fallbackTitle: '脏字节样本',
    );
    expect(result.chapters.single.content, contains('桥头下着雨 & 风很大'));
  });

  test('谎报 UTF-8 的 GBK 正文可回退解码', () {
    final text = Uint8List.fromList(
      gbk.encode('<body><p>桥头下着雨，他走进巷子。</p></body>'),
    );
    final result = MobiImporter.parse(
      _sampleMobi(text: text),
      fallbackTitle: 'GBK 样本',
    );
    expect(result.chapters.single.content, contains('桥头下着雨'));
  });

  test('解析结果打包成内部 EPUB 后可被 EpubImporter 回读', () {
    final result = MobiImporter.parse(
      _sampleMobi(
        text: Uint8List.fromList(utf8.encode(_sampleHtml)),
        exthTitle: '江湖夜雨',
        exthAuthor: '测试作者',
      ),
      fallbackTitle: 'x',
    );
    final epub = EpubBuilder.build(
      title: result.title,
      author: result.author,
      chapters: [
        for (final chapter in result.chapters)
          EpubChapter(
            title: chapter.title,
            html: EpubBuilder.textToHtml(chapter.content),
          ),
      ],
    );
    final meta = EpubImporter.inspect(epub, fallbackTitle: 'x');
    expect(meta.title, '江湖夜雨');
    expect(meta.author, '测试作者');
    expect(meta.chapterCount, result.chapters.length);
  });

  test('MOBI 封面（EXTH 129 图片记录）可被提取', () {
    final result = MobiImporter.parse(
      _sampleMobi(
        text: Uint8List.fromList(utf8.encode(_sampleHtml)),
        coverImages: [Uint8List.fromList(_png1x1)],
      ),
      fallbackTitle: '带封面样书',
    );
    expect(result.coverBytes, isNotNull);
    // 剥离 "IMG " 封装头后应为 PNG 魔数 89 50 4E 47。
    expect(result.coverBytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
  });

  test('无 EXTH 129 时仍可从图片记录回退提取封面', () {
    final result = MobiImporter.parse(
      _sampleMobi(
        text: Uint8List.fromList(utf8.encode(_sampleHtml)),
        coverImages: [Uint8List.fromList(_png1x1)],
        coverExth: false,
      ),
      fallbackTitle: '回退封面',
    );
    expect(result.coverBytes, isNotNull);
  });

  test('无 EXTH 129 时回退取面积最大的图，而非第一张插图', () {
    final small = Uint8List.fromList(
      img.encodePng(img.Image(width: 4, height: 4)),
    );
    final large = Uint8List.fromList(
      img.encodePng(img.Image(width: 40, height: 60)),
    );
    // 小图在前、大图在后，都没有 EXTH 129。
    final result = MobiImporter.parse(
      _sampleMobi(
        text: Uint8List.fromList(utf8.encode(_sampleHtml)),
        coverImages: [small, large],
        coverExth: false,
      ),
      fallbackTitle: '多图回退',
    );
    expect(result.coverBytes, isNotNull);
    final decoded = img.decodeImage(result.coverBytes!);
    expect(decoded?.width, 40);
    expect(decoded?.height, 60);
  });

  test('没有封面图的 MOBI 解析结果为 null 且不报错', () {
    final result = MobiImporter.parse(
      _sampleMobi(
        text: Uint8List.fromList(utf8.encode(_sampleHtml)),
      ),
      fallbackTitle: '无封面',
    );
    expect(result.coverBytes, isNull);
    expect(result.chapters.length, 3);
  });

  test('导入服务把 MOBI 错误映射为统一导入错误', () async {
    final kv = MemoryKeyValueStore();
    final service = ReaderImportService(
      books: ReaderBookStore(kv),
      activity: ReaderActivityStore(kv),
    );
    await expectLater(
      service.importMobi(
        bytes: Uint8List.fromList(utf8.encode('not a mobi')),
        fileName: 'x.mobi',
      ),
      throwsA(
        isA<ReaderImportException>().having(
          (e) => e.kind,
          'kind',
          ReaderImportError.unsupportedFormat,
        ),
      ),
    );
  });

  test('localMobi 角标、归类与 JSON 往返', () {
    expect(ReaderBookSource.localMobi.label, 'MOBI');
    expect(ReaderBookSource.localMobi.isLocalImport, isTrue);
    expect(
      ReaderBookSourceX.fromStorage('localMobi'),
      ReaderBookSource.localMobi,
    );
    expect(
      shelfOriginOf(ReaderBookSource.localMobi),
      ShelfOrigin.localBook,
    );
    final book = ReaderBook(
      id: 'b1',
      title: '测试书',
      source: ReaderBookSource.localMobi,
      fileName: 'book.epub',
      chapterCount: 3,
      addedAt: DateTime(2026, 1, 1),
    );
    expect(ReaderBook.fromJson(book.toJson()).source, ReaderBookSource.localMobi);
  });
}

/// 只使用 PalmDOC 字面量串（每 8 字节一组）压缩，覆盖最常规的 MOBI 生成结果。
Uint8List _palmdocLiterals(Uint8List src) {
  final out = <int>[];
  for (var i = 0; i < src.length;) {
    final length = math.min(8, src.length - i);
    out.add(length);
    for (var j = 0; j < length; j++) {
      out.add(src[i + j]);
    }
    i += length;
  }
  return Uint8List.fromList(out);
}

/// 内存构造最小 PalmDB：1 条 PalmDOC/MOBI 头记录 + 1 条正文记录。
Uint8List _sampleMobi({
  required Uint8List text,
  int compression = 1,
  int encryption = 0,
  int encoding = 65001,
  String type = 'BOOK',
  String creator = 'MOBI',
  bool mobiHeader = true,
  String? exthTitle,
  String? exthAuthor,
  int? declaredLength,
  List<Uint8List>? coverImages,
  bool coverExth = true,
}) {
  final exth = <int, Object>{};
  if (exthTitle != null) exth[503] = exthTitle;
  if (exthAuthor != null) exth[100] = exthAuthor;

  final rec0 = <int>[];
  _u16(rec0, compression);
  _u16(rec0, 0);
  _u32(rec0, declaredLength ?? text.length);
  _u16(rec0, 1);
  _u16(rec0, 4096);
  _u16(rec0, encryption);
  _u16(rec0, 0);
  if (mobiHeader) {
    final header = Uint8List(232);
    final data = ByteData.sublistView(header);
    _ascii(header, 0, 'MOBI');
    data.setUint32(4, 232);
    data.setUint32(8, 2);
    data.setUint32(12, encoding);
    data.setUint32(0x80, exth.isEmpty ? 0 : 0x40);
    rec0.addAll(header);
    if (exth.isNotEmpty) rec0.addAll(_exth(exth));
  }

  final records = <Uint8List>[Uint8List.fromList(rec0), text];
  if (coverImages != null) {
    for (final cover in coverImages) {
      final img = <int>[...ascii.encode('IMG '), 0, 0, 0, 1];
      _u32(img, cover.length);
      img.addAll(cover);
      records.add(Uint8List.fromList(img));
    }
    if (coverExth) exth[129] = records.length - coverImages.length;
  }
  final headerSize = 78 + records.length * 8 + 2;
  final offsets = <int>[];
  var cursor = headerSize;
  for (final record in records) {
    offsets.add(cursor);
    cursor += record.length;
  }

  final out = Uint8List(cursor);
  final data = ByteData.sublistView(out);
  _ascii(out, 0, 'Test Book');
  data.setUint16(76, records.length);
  _ascii(out, 60, type);
  _ascii(out, 64, creator);
  for (var i = 0; i < records.length; i++) {
    data.setUint32(78 + i * 8, offsets[i]);
  }
  for (var i = 0; i < records.length; i++) {
    out.setRange(offsets[i], offsets[i] + records[i].length, records[i]);
  }
  return out;
}

List<int> _exth(Map<int, Object> entries) {
  final body = <int>[];
  for (final entry in entries.entries) {
    late final List<int> value;
    if (entry.value is String) {
      value = utf8.encode(entry.value as String);
    } else {
      final v = entry.value as int;
      value = [
        (v >> 24) & 0xff,
        (v >> 16) & 0xff,
        (v >> 8) & 0xff,
        v & 0xff,
      ];
    }
    _u32(body, entry.key);
    _u32(body, 8 + value.length);
    body.addAll(value);
  }
  final out = <int>[...ascii.encode('EXTH')];
  _u32(out, 12 + body.length);
  _u32(out, entries.length);
  out.addAll(body);
  return out;
}

/// 最小合法 PNG（1x1 透明），用于构造封面图记录。
const List<int> _png1x1 = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

void _ascii(Uint8List bytes, int offset, String value) {
  for (var i = 0; i < value.length; i++) {
    bytes[offset + i] = value.codeUnitAt(i);
  }
}

void _u16(List<int> out, int value) {
  out.add((value >> 8) & 0xff);
  out.add(value & 0xff);
}

void _u32(List<int> out, int value) {
  out.add((value >> 24) & 0xff);
  out.add((value >> 16) & 0xff);
  out.add((value >> 8) & 0xff);
  out.add(value & 0xff);
}
