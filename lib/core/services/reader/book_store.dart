import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../api/key_value_store.dart';
import '../../domain/reader_book.dart';
import 'book_file_store.dart';

/// 本地书书架排序方式（独立于 B 站收藏的排序）。
enum ReaderSortMode { recent, added, title }

extension ReaderSortModeX on ReaderSortMode {
  String get label => switch (this) {
    ReaderSortMode.recent => '最近阅读',
    ReaderSortMode.added => '导入时间',
    ReaderSortMode.title => '标题',
  };
}

/// 本地书元数据存储（docs/reader-design.md §2.2）。
///
/// 独立于 [ShelfController]：本地书全链路只写 `reader_*` 数据域，
/// 不碰 `shelf` / `play_history` / `play_log`，保证现有 B 站链路零改动。
class ReaderBookStore extends ChangeNotifier {
  ReaderBookStore(this._kv);

  static const storageKey = 'reader_books';

  final KeyValueStore _kv;
  final List<ReaderBook> _books = [];

  /// 文件缺失的书籍 id（还原备份 / 手工清缓存后可能出现）。
  final Set<String> _missing = {};

  bool _loaded = false;

  bool get loaded => _loaded;

  /// 未删除的本地书（列表按需排序，返回不可变视图）。
  List<ReaderBook> get books =>
      List.unmodifiable(_books.where((b) => !b.removed));

  /// 最近删除、可撤销的书籍。
  ReaderBook? recentlyRemoved() {
    final removed = _books.where((b) => b.removed).toList();
    if (removed.isEmpty) return null;
    removed.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return removed.first;
  }

  ReaderBook? byId(String id) {
    for (final book in _books) {
      if (book.id == id) return book;
    }
    return null;
  }

  bool isMissing(String id) => _missing.contains(id);

  /// 读取元数据，并顺带检查书籍文件是否仍在。
  Future<void> load() async {
    final raw = _kv.getString(storageKey);
    _books.clear();
    _missing.clear();
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              _books.add(ReaderBook.fromJson(item));
            } else if (item is Map) {
              _books.add(ReaderBook.fromJson(Map<String, dynamic>.from(item)));
            }
          }
        }
      } catch (e) {
        debugPrint('[reader] 读取 reader_books 失败：$e');
      }
    }
    _loaded = true;
    await _refreshMissing();
    notifyListeners();
  }

  Future<void> _refreshMissing() async {
    _missing.clear();
    for (final book in _books) {
      if (book.removed) continue;
      final exists = await readerBookFileExists(book.id, book.fileName);
      if (!exists) _missing.add(book.id);
    }
  }

  Future<void> _persist() async {
    await _kv.setString(
      storageKey,
      jsonEncode([for (final book in _books) book.toJson()]),
    );
  }

  /// 新增（同 id 覆盖），并标记文件存在。
  Future<void> add(ReaderBook book) async {
    _books.removeWhere((b) => b.id == book.id);
    _books.add(book);
    _missing.remove(book.id);
    notifyListeners();
    await _persist();
  }

  /// 更新元数据（阅读进度 / 解析后的书名等）。
  Future<void> upsert(ReaderBook book) async {
    final index = _books.indexWhere((b) => b.id == book.id);
    if (index < 0) {
      await add(book);
      return;
    }
    _books[index] = book;
    _missing.remove(book.id);
    notifyListeners();
    await _persist();
  }

  /// 软删除（左滑 / 多选），文件与进度保留，可撤销。
  Future<void> remove(String id) async {
    final index = _books.indexWhere((b) => b.id == id);
    if (index < 0) return;
    _books[index] = _books[index].copyWith(removed: true);
    notifyListeners();
    await _persist();
  }

  /// 批量软删除。
  Future<void> removeAll(Iterable<String> ids) async {
    var changed = false;
    for (final id in ids) {
      final index = _books.indexWhere((b) => b.id == id);
      if (index < 0) continue;
      _books[index] = _books[index].copyWith(removed: true);
      changed = true;
    }
    if (changed) {
      notifyListeners();
      await _persist();
    }
  }

  /// 撤销软删除。
  Future<void> restore(ReaderBook book) async {
    final index = _books.indexWhere((b) => b.id == book.id);
    final restored = book.copyWith(removed: false);
    if (index < 0) {
      _books.add(restored);
    } else {
      _books[index] = restored;
    }
    _missing.remove(book.id);
    notifyListeners();
    await _persist();
  }

  /// 彻底移除记录（调用方负责先删书籍文件目录）。
  Future<void> purge(String id) async {
    _books.removeWhere((b) => b.id == id);
    _missing.remove(id);
    notifyListeners();
    await _persist();
  }

  /// 更新阅读进度（M9.2 阅读页节流回调直接调用）。
  Future<void> updateProgress(
    String id, {
    required int chapterIndex,
    required double fraction,
    int? ttsParaIndex,
    DateTime? lastReadAt,
  }) async {
    final index = _books.indexWhere((b) => b.id == id);
    if (index < 0) return;
    _books[index] = _books[index].copyWith(
      lastChapterIndex: chapterIndex,
      lastFraction: fraction,
      lastTtsParaIndex: ttsParaIndex,
      lastReadAt: lastReadAt ?? DateTime.now(),
    );
    notifyListeners();
    await _persist();
  }

  /// 排序后的本地书列表。
  List<ReaderBook> sorted(ReaderSortMode mode) {
    final list = books.toList();
    switch (mode) {
      case ReaderSortMode.recent:
        list.sort((a, b) {
          final at = a.lastReadAt ?? a.addedAt;
          final bt = b.lastReadAt ?? b.addedAt;
          return bt.compareTo(at);
        });
      case ReaderSortMode.added:
        list.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      case ReaderSortMode.title:
        list.sort((a, b) => a.title.compareTo(b.title));
    }
    return list;
  }
}
