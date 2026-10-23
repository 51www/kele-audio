/// 六张表的 DAO 封装（PRD §7.5）。
///
/// 原则：UI 与用例只认 DAO，不直接碰 [Table] / key；
/// 写操作内部走 [LocalDatabase.ensureCreated]，保证建表先行。
library;

import '../domain/album.dart';
import '../domain/records.dart';
import 'local_database.dart';

/// `album` 表：专辑缓存（不存播放地址）。
class AlbumDao {
  AlbumDao(this._db);

  final LocalDatabase _db;

  Future<void> upsert(Album album) async {
    await _db.ensureCreated();
    await _db.albums.upsert(album);
  }

  Future<void> upsertAll(Iterable<Album> albums) async {
    await _db.ensureCreated();
    await _db.albums.upsertAll(albums);
  }

  Album? get(String id) => _db.albums.byId(id);

  List<Album> byCategory(String categoryId) =>
      _db.albums.where((a) => a.categoryId == categoryId);

  List<Album> recent({int limit = 20}) {
    final rows = _db.albums.all()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return rows.take(limit).toList();
  }

  int get count => _db.albums.count;
}

/// `chapter` 表：章节（分 P / 合集条目）。
class ChapterDao {
  ChapterDao(this._db);

  final LocalDatabase _db;

  Future<void> upsertAll(Iterable<Chapter> chapters) async {
    await _db.ensureCreated();
    await _db.chapters.upsertAll(chapters);
  }

  List<Chapter> byAlbum(String albumId) {
    final rows = _db.chapters.where((c) => c.albumId == albumId);
    rows.sort((a, b) => a.index.compareTo(b.index));
    return rows;
  }

  Chapter? get(String chapterId) => _db.chapters.byId(chapterId);

  int countFor(String albumId) =>
      _db.chapters.where((c) => c.albumId == albumId).length;

  /// P-04：给定章节的下一章（列表循环时回到第一环）。
  Chapter? nextOf(String chapterId) {
    final cur = _db.chapters.byId(chapterId);
    if (cur == null) return null;
    final list = byAlbum(cur.albumId);
    final i = list.indexWhere((c) => c.id == chapterId);
    if (i < 0 || i + 1 >= list.length) return null;
    return list[i + 1];
  }
}

/// `shelf` 表：书架收藏（仅本地）。
class ShelfDao {
  ShelfDao(this._db);

  final LocalDatabase _db;

  Future<void> add(String albumId) async {
    await _db.ensureCreated();
    if (_db.shelf.byId(albumId) != null) return;
    await _db.shelf.upsert(ShelfItem(
      albumId: albumId,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  Future<void> remove(String albumId) async {
    await _db.ensureCreated();
    await _db.shelf.deleteById(albumId);
  }

  bool has(String albumId) => _db.shelf.byId(albumId) != null;

  int get count => _db.shelf.count;

  /// 默认按最近收听排序（PRD §5.3）。
  List<ShelfItem> list() {
    final rows = _db.shelf.all()
      ..sort((a, b) {
        final la = a.lastPlayedAt > 0 ? a.lastPlayedAt : a.createdAt;
        final lb = b.lastPlayedAt > 0 ? b.lastPlayedAt : b.createdAt;
        return lb.compareTo(la);
      });
    return rows;
  }
}

/// `play_history` 表：断点续播 / 历史页（P-03、P-04）。
class PlayHistoryDao {
  PlayHistoryDao(this._db);

  final LocalDatabase _db;

  Future<void> put(PlayHistory entry) async {
    await _db.ensureCreated();
    await _db.playHistory.upsert(entry);
  }

  PlayHistory? forChapter(String albumId, String chapterId) =>
      _db.playHistory.byId('$albumId|$chapterId');

  /// 专辑内最后一次收听记录（跨章续播定位点）。
  PlayHistory? latestOfAlbum(String albumId) {
    final rows = _db.playHistory.where((h) => h.albumId == albumId)
      ..sort((a, b) => b.playedAt.compareTo(a.playedAt));
    return rows.isEmpty ? null : rows.first;
  }

  List<PlayHistory> recent({int limit = 50}) {
    final rows = _db.playHistory.all()
      ..sort((a, b) => b.playedAt.compareTo(a.playedAt));
    return rows.take(limit).toList();
  }

  Future<void> removeAlbum(String albumId) async {
    await _db.ensureCreated();
    await _db.playHistory.removeWhere((h) => h.albumId == albumId);
  }

  Future<void> clear() async {
    await _db.ensureCreated();
    await _db.playHistory.clear();
  }

  int get count => _db.playHistory.count;
}

/// `play_log` 表：按天收听日志（M8 统计聚合，M1 建表埋口）。
class PlayLogDao {
  PlayLogDao(this._db);

  final LocalDatabase _db;

  Future<void> add(PlayLogEntry entry) async {
    await _db.ensureCreated();
    await _db.playLogs.upsert(entry);
  }

  int totalSeconds() =>
      _db.playLogs.all().fold<int>(0, (sum, e) => sum + e.durationSec);

  List<PlayLogEntry> byDate(String date) =>
      _db.playLogs.where((e) => e.date == date);

  int get count => _db.playLogs.count;
}

/// `download` 表：离线索引（M8 使用，M1 建表 + 基本读写）。
class DownloadDao {
  DownloadDao(this._db);

  final LocalDatabase _db;

  Future<void> upsert(DownloadTask task) async {
    await _db.ensureCreated();
    await _db.downloads.upsert(task);
  }

  DownloadTask? get(String chapterId) => _db.downloads.byId(chapterId);

  Future<void> remove(String chapterId) async {
    await _db.ensureCreated();
    await _db.downloads.deleteById(chapterId);
  }

  int totalBytes() =>
      _db.downloads.all().fold<int>(0, (sum, d) => sum + d.sizeBytes);

  int get count => _db.downloads.count;
}

/// DAO 集合，DI 时一次性创建。
class Daos {
  Daos(this.db)
      : albums = AlbumDao(db),
        chapters = ChapterDao(db),
        shelf = ShelfDao(db),
        playHistory = PlayHistoryDao(db),
        playLogs = PlayLogDao(db),
        downloads = DownloadDao(db);

  final LocalDatabase db;
  final AlbumDao albums;
  final ChapterDao chapters;
  final ShelfDao shelf;
  final PlayHistoryDao playHistory;
  final PlayLogDao playLogs;
  final DownloadDao downloads;
}
