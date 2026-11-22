import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../api/key_value_store.dart';
import '../../domain/reader_annotation.dart';

/// 划线标注存储（按书分 key + 一个书 id 索引）。
///
/// - `reader_annotation_books`：有标注的 bookId 列表（JSON 数组）；
/// - `reader_annotations_{bookId}`：该书全部标注（JSON 数组）。
///
/// 与阅读进度同风格：shared_preferences JSON、不引入数据库。
class ReaderAnnotationStore extends ChangeNotifier {
  ReaderAnnotationStore(this._kv);

  final KeyValueStore _kv;

  static const String booksKey = 'reader_annotation_books';

  static String keyFor(String bookId) => 'reader_annotations_$bookId';

  final Map<String, List<ReaderAnnotation>> _byBook =
      <String, List<ReaderAnnotation>>{};

  bool _loaded = false;
  bool get loaded => _loaded;

  List<ReaderAnnotation> byBook(String bookId) =>
      List<ReaderAnnotation>.unmodifiable(_byBook[bookId] ?? const []);

  /// 全量标注（最近更新在前），供「我的划线」页与导出使用。
  List<ReaderAnnotation> get all {
    final items = _byBook.values.expand((e) => e).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List<ReaderAnnotation>.unmodifiable(items);
  }

  int countFor(String bookId) => _byBook[bookId]?.length ?? 0;

  Future<void> load() async {
    _byBook.clear();
    for (final bookId in _readBookIds()) {
      final raw = _kv.getString(keyFor(bookId));
      if (raw == null || raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        final items = ReaderAnnotation.decodeList(decoded);
        if (items.isNotEmpty) _byBook[bookId] = items;
      } catch (e) {
        debugPrint('[reader] 读取划线失败（$bookId）：$e');
      }
    }
    _loaded = true;
    notifyListeners();
  }

  List<String> _readBookIds() {
    final raw = _kv.getString(booksKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded.whereType<String>().toList();
    } catch (e) {
      debugPrint('[reader] 读取划线书索引失败：$e');
      return const [];
    }
  }

  Future<void> upsert(ReaderAnnotation annotation) async {
    final items = <ReaderAnnotation>[
      ...(_byBook[annotation.bookId] ?? const []),
    ];
    final index = items.indexWhere((e) => e.id == annotation.id);
    if (index >= 0) {
      items[index] = annotation;
    } else {
      items.add(annotation);
    }
    _sort(items);
    _byBook[annotation.bookId] = items;
    await _persist(annotation.bookId);
    notifyListeners();
  }

  Future<void> remove(String bookId, String annotationId) async {
    final items = _byBook[bookId];
    if (items == null) return;
    final next = items.where((e) => e.id != annotationId).toList();
    if (next.length == items.length) return;
    if (next.isEmpty) {
      _byBook.remove(bookId);
    } else {
      _byBook[bookId] = next;
    }
    await _persist(bookId);
    notifyListeners();
  }

  /// 删书时清理（与阅读进度删除时机一致）。
  Future<void> removeBook(String bookId) async {
    if (_byBook.remove(bookId) == null) return;
    await _persist(bookId);
    notifyListeners();
  }

  Future<void> _persist(String bookId) async {
    final ids = _byBook.keys.toList();
    await _kv.setString(booksKey, jsonEncode(ids));
    final items = _byBook[bookId];
    if (items == null || items.isEmpty) {
      await _kv.remove(keyFor(bookId));
    } else {
      await _kv.setString(keyFor(bookId), ReaderAnnotation.encodeList(items));
    }
  }

  static void _sort(List<ReaderAnnotation> items) {
    items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }
}
