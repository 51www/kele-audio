import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kele_audio/core/api/key_value_store.dart';
import 'package:kele_audio/core/domain/reader_book.dart';
import 'package:kele_audio/core/services/reader/book_store.dart';
import 'package:kele_audio/core/services/reader/epub_importer.dart';
import 'package:kele_audio/core/services/reader/reader_activity_store.dart';
import 'package:kele_audio/core/services/reader/txt_importer.dart';
import 'package:kele_audio/core/services/reader/txt_to_epub.dart';
import 'package:kele_audio/core/services/reader/web_article_importer.dart';

void main() {
  const sample = '''
第一章 初入江湖
少年提剑下山，春风拂面。他并不知道，山下的世界远比想象中复杂。

第二章 夜雨客栈
客栈里灯火昏黄，老板娘端来一碗热汤。窗外雨声渐急，像是有人敲打窗棂。

第三章 旧人重逢
第二天清晨，他在桥头遇见多年未见的故人，两人一时无言。
''';

  group('TXT 编码识别与切章', () {
    test('UTF-8 文本按章节标题切分', () {
      final result = TxtImporter.parse(
        Uint8List.fromList(utf8.encode(sample)),
        fallbackTitle: '江湖行',
      );
      expect(result.encoding, 'UTF-8');
      expect(result.chapters.length, 3);
      expect(result.chapters.first.title, '第一章 初入江湖');
      expect(result.chapters.last.title, '第三章 旧人重逢');
      expect(result.chapters.last.content, contains('桥头'));
    });

    test('GBK 文本自动回退 GBK 解码', () {
      final bytes = Uint8List.fromList(gbk.encode(sample));
      final result = TxtImporter.parse(bytes, fallbackTitle: '江湖行');
      expect(result.encoding, 'GBK');
      expect(result.chapters.length, 3);
      expect(result.chapters.first.content, contains('少年提剑下山'));
    });

    test('无章节标题的长文本按字数兜底切章', () {
      final text = List.filled(300, '这一段没有任何章节标题，只是很长的正文。').join('\n\n');
      final result = TxtImporter.parse(
        Uint8List.fromList(utf8.encode(text)),
        fallbackTitle: '无名书',
      );
      expect(result.chapters.length, greaterThan(1));
      expect(result.chapters.first.title, '第1章');
      expect(result.chapters.first.content.isNotEmpty, isTrue);
    });

    test('连续空行与行尾空白被清洗', () {
      final cleaned = TxtImporter.clean('第一行   \r\n\r\n\r\n\r\n第二行\t \r\n');
      expect(cleaned, '第一行\n\n第二行');
    });
  });

  group('TXT / 网页 → EPUB', () {
    test('打包产物包含 mimetype、OPF 与章节文件', () {
      final bytes = EpubBuilder.build(
        title: '江湖行',
        author: '佚名',
        chapters: [
          const EpubChapter(title: '第一章', html: '<p>正文一</p>'),
          const EpubChapter(title: '第二章', html: '<p>正文二</p>'),
        ],
      );
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(archive.files.first.name, 'mimetype');
      final names = archive.files.map((f) => f.name).toList();
      expect(names, contains('META-INF/container.xml'));
      expect(names, contains('OEBPS/content.opf'));
      expect(names, contains('OEBPS/chapter1.xhtml'));
      expect(names, contains('OEBPS/nav.xhtml'));
      expect(names, contains('OEBPS/toc.ncx'));
    });

    test('打包后的 EPUB 可被导入器解析出标题与章节数', () {
      final bytes = EpubBuilder.build(
        title: '江湖行',
        author: '佚名',
        chapters: const [
          EpubChapter(title: '第一章', html: '<p>正文一</p>'),
          EpubChapter(title: '第二章', html: '<p>正文二</p>'),
        ],
      );
      final meta = EpubImporter.inspect(bytes, fallbackTitle: '兜底');
      expect(meta.title, '江湖行');
      expect(meta.author, '佚名');
      expect(meta.chapterCount, 2);
    });

    test('伪造扩展名的非 ZIP 内容被拒绝', () {
      expect(
        () => EpubImporter.inspect(
          Uint8List.fromList(utf8.encode('not a zip')),
          fallbackTitle: '坏文件',
        ),
        throwsA(isA<EpubImportException>()),
      );
    });

    test('网页 HTML 按 h1/h2 切章', () {
      final chapters = WebArticleImporter.splitHtml(
        '<p>导语</p><h2>第一节</h2><p>内容一</p><h2>第二节</h2><p>内容二</p>',
        title: '测试文章',
      );
      expect(chapters.length, 2); // 两个标题章（过短的导语不单独成章）
      expect(chapters.first.title, '第一节');
      expect(chapters.last.html, contains('内容二'));
    });

    test('空链接与非法链接在抓取前给出明确提示', () async {
      await expectLater(
        WebArticleImporter.fetch('   '),
        throwsA(
          isA<WebImportException>()
              .having((e) => e.kind, 'kind', WebImportError.invalidUrl)
              .having((e) => e.message, 'message', contains('请输入文章链接')),
        ),
      );
      await expectLater(
        WebArticleImporter.fetch('http://'),
        throwsA(
          isA<WebImportException>()
              .having((e) => e.kind, 'kind', WebImportError.invalidUrl)
              .having((e) => e.message, 'message', contains('链接格式不正确')),
        ),
      );
    });

    test('正文阈值调整为 200 字，低于阈值不视为导入成功', () {
      expect(WebArticleImporter.minTextLength, 200);
    });
  });

  group('ReaderBook 模型与存储', () {
    test('JSON 往返与进度文案', () {
      final book = ReaderBook(
        id: 'b1',
        title: '江湖行',
        source: ReaderBookSource.localTxt,
        fileName: 'book.epub',
        chapterCount: 10,
        addedAt: DateTime(2026, 11, 4),
        lastReadAt: DateTime(2026, 11, 4, 12),
        lastChapterIndex: 4,
        lastFraction: 0.5,
      );
      final restored = ReaderBook.fromJson(book.toJson());
      expect(restored.title, '江湖行');
      expect(restored.source, ReaderBookSource.localTxt);
      expect(restored.overallProgress, closeTo(0.45, 0.001));
      expect(restored.progressText, contains('已读 5/10 章'));
    });

    test('软删除可撤销，进度可更新', () async {
      final kv = MemoryKeyValueStore();
      final store = ReaderBookStore(kv);
      final book = ReaderBook(
        id: 'b2',
        title: '测试书',
        source: ReaderBookSource.localEpub,
        fileName: 'book.epub',
        chapterCount: 3,
        addedAt: DateTime(2026, 11, 4),
      );
      await store.add(book);
      expect(store.books.length, 1);

      await store.remove('b2');
      expect(store.books, isEmpty);
      expect(store.recentlyRemoved()?.id, 'b2');

      await store.restore(book);
      expect(store.books.length, 1);

      await store.updateProgress('b2', chapterIndex: 1, fraction: 0.25);
      final updated = store.byId('b2')!;
      expect(updated.lastChapterIndex, 1);
      expect(updated.lastFraction, 0.25);
      expect(updated.lastReadAt, isNotNull);
      expect(kv.getString(ReaderBookStore.storageKey), contains('"b2"'));
    });
  });

  group('阅读活动埋点', () {
    test('同日同书同时长合并，按日期聚合', () async {
      final kv = MemoryKeyValueStore();
      final store = ReaderActivityStore(kv);
      await store.logDuration(
        bookId: 'b1',
        durationSec: 60,
        mode: ReaderActivityMode.reading,
        at: DateTime(2026, 11, 4),
      );
      await store.logDuration(
        bookId: 'b1',
        durationSec: 30,
        mode: ReaderActivityMode.reading,
        at: DateTime(2026, 11, 4, 12),
      );
      await store.logDuration(
        bookId: 'b1',
        durationSec: 20,
        mode: ReaderActivityMode.listening,
        at: DateTime(2026, 11, 4),
      );

      expect(store.log.length, 2);
      expect(store.totalSeconds, 110);
      expect(store.secondsByDate()['2026-11-04'], 110);
      expect(store.secondsSince(DateTime(2026, 11, 4)), 110);
      expect(store.secondsSince(DateTime(2026, 11, 5)), 0);
    });

    test('删除书籍同时清理历史与日志', () async {
      final kv = MemoryKeyValueStore();
      final store = ReaderActivityStore(kv);
      await store.recordHistory(
        ReaderHistoryEntry(
          bookId: 'b1',
          bookTitle: '测试书',
          chapterTitle: '第一章',
          mode: ReaderActivityMode.reading,
          at: DateTime(2026, 11, 4),
        ),
      );
      await store.logDuration(
        bookId: 'b1',
        durationSec: 60,
        mode: ReaderActivityMode.reading,
      );
      await store.removeBook('b1');
      expect(store.history, isEmpty);
      expect(store.log, isEmpty);
    });
  });
}
