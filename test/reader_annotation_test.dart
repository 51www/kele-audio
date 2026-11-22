import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kele_audio/core/api/key_value_store.dart';
import 'package:kele_audio/core/domain/reader_annotation.dart';
import 'package:kele_audio/core/services/backup/backup_keys.dart';
import 'package:kele_audio/core/services/reader/annotation_export.dart';
import 'package:kele_audio/core/services/reader/reader_annotation_store.dart';

ReaderAnnotation _annotation({
  required String id,
  String bookId = 'book-1',
  String text = 'The quick brown fox',
  String? note,
}) =>
    ReaderAnnotation(
      id: id,
      bookId: bookId,
      bookTitle: '英文原著',
      chapterIndex: 2,
      chapterTitle: 'Chapter 2',
      cfi: 'epubcfi(/6/8!/4/2,$id)',
      text: text,
      color: ReaderAnnotationColor.yellow,
      note: note,
      createdAt: DateTime(2026, 11, 22, 10),
      updatedAt: DateTime(2026, 11, 22, 10),
    );

void main() {
  group('划线模型', () {
    test('JSON 往返保留颜色与笔记', () {
      final source = _annotation(id: 'a1', note: '重点');
      final decoded = ReaderAnnotation.fromJson(source.toJson());
      expect(decoded.id, 'a1');
      expect(decoded.color, ReaderAnnotationColor.yellow);
      expect(decoded.note, '重点');
      expect(decoded.hasNote, isTrue);
    });

    test('损坏列表被跳过', () {
      final items = ReaderAnnotation.decodeList([
        _annotation(id: 'a1').toJson(),
        {'id': '', 'bookId': 'x'},
        'not a map',
      ]);
      expect(items.length, 1);
    });
  });

  group('划线存储', () {
    test('按书增删改并维护书索引', () async {
      final kv = MemoryKeyValueStore();
      final store = ReaderAnnotationStore(kv);
      await store.load();

      await store.upsert(_annotation(id: 'a1'));
      await store.upsert(_annotation(id: 'a2', bookId: 'book-2'));
      expect(store.countFor('book-1'), 1);
      expect(store.all.length, 2);
      expect(jsonDecode(kv.getString(ReaderAnnotationStore.booksKey)!), contains('book-2'));

      final reloaded = ReaderAnnotationStore(kv);
      await reloaded.load();
      expect(reloaded.byBook('book-1').single.id, 'a1');

      await reloaded.remove('book-1', 'a1');
      expect(reloaded.byBook('book-1'), isEmpty);
      expect(
        jsonDecode(kv.getString(ReaderAnnotationStore.booksKey)!),
        isNot(contains('book-1')),
      );

      await reloaded.removeBook('book-2');
      expect(reloaded.all, isEmpty);
    });
  });

  group('划线导出', () {
    test('只导出划线文本，一行一条，不含标题与元数据', () {
      final items = [
        _annotation(id: 'a1', text: '静夜思', note: '李白'),
        _annotation(id: 'a2', text: '床前明月光'),
      ];
      final text = utf8.decode(AnnotationExportService.buildText(items));
      expect(text, '静夜思\n床前明月光');
      expect(text, isNot(contains('李白')));
      expect(text, isNot(contains('Chapter')));
    });
  });

  test('备份白名单覆盖划线索引与动态键前缀', () {
    expect(
      BackupWhitelist.settingsItems.map((e) => e.key),
      contains('reader_annotation_books'),
    );
    expect(
      BackupWhitelist.readerAnnotationPrefix,
      'reader_annotations_',
    );
  });
}
