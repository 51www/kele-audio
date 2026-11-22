import '../api/key_value_store.dart';
import '../data/daos.dart';
import '../domain/reader_book.dart';
import 'reader/book_store.dart';
import 'reader/reader_progress_store.dart';

/// 记录类型：阅读（本地书） / 听书（B 站专辑）。
enum RecentRecordKind { reading, listening }

extension RecentRecordKindX on RecentRecordKind {
  String get label => switch (this) {
    RecentRecordKind.reading => '阅读',
    RecentRecordKind.listening => '听书',
  };
}

/// 一条「最近阅读 / 听书记录」。
///
/// 只是现有数据的**投影**，不新建持久化：
/// - 阅读：`ReaderBookStore`（lastReadAt）+ `ReaderProgressStore`（页码快照）；
/// - 听书：`play_history` 按专辑取最新一条 + `chapter` 换算集数。
class RecentRecord {
  const RecentRecord({
    required this.kind,
    required this.id,
    required this.title,
    required this.at,
    this.coverUrl = '',
    this.badgeLabel = '',
    this.page,
    this.chapterNumber = 0,
    this.chapterId = '',
    this.chapterPosition = -1,
    this.positionSec = 0,
    this.finished = false,
  });

  final RecentRecordKind kind;

  /// 阅读 = bookId；听书 = albumId。
  final String id;
  final String title;
  final DateTime at;

  /// 封面地址（本地书暂无封面，留空走类型角标占位）。
  final String coverUrl;

  /// 本地书来源角标（TXT / EPUB / PDF / MOBI / 网页）。
  final String badgeLabel;

  /// 阅读页码（拿不到时为 null）。
  final int? page;

  /// 阅读章节（1 基） / 听书集数（1 基），0 表示未知。
  final int chapterNumber;

  final String chapterId;

  /// 听书章节在 `chapters.byAlbum` 中的位置（播放定位用）。
  final int chapterPosition;

  /// 听书断点秒数。
  final int positionSec;

  /// 进度是否已到末尾（书 / 专辑已读完）。
  final bool finished;

  /// 相对时间：今天 / 昨天 / MM-DD。
  String get atLabel {
    final now = DateTime.now();
    final day = DateTime(at.year, at.month, at.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    if (diff <= 0) return '今天';
    if (diff == 1) return '昨天';
    final month = at.month.toString().padLeft(2, '0');
    final date = at.day.toString().padLeft(2, '0');
    return '$month-$date';
  }

  /// 「第 x 页」/「第 x 集」；未知进度时为空串。
  String get progressLabel {
    if (kind == RecentRecordKind.reading) {
      if (page != null && page! > 0) return '第 $page 页';
      if (chapterNumber > 0) return '第 $chapterNumber 章';
      return '';
    }
    if (chapterNumber > 0) return '第 $chapterNumber 集';
    return '';
  }

  /// 副行：`阅读 · 第 12 页 · 今天`。
  String get subtitle {
    final parts = <String>[kind.label, if (progressLabel.isNotEmpty) progressLabel, atLabel];
    return parts.join(' · ');
  }

  /// 续读条前缀 + 书名（进度部分单独渲染，长标题不会把集数挤掉）。
  String get continueTitle {
    final verb = kind == RecentRecordKind.reading ? '继续阅读' : '继续收听';
    return '$verb《$title》';
  }
}

/// 记录列表构建 + 「清空」。
///
/// 「清空」只在 KV 记一个时间戳，**不删** `play_history` / 书架 / 阅读进度：
/// 底层数据仍用于续播与书架进度，清空只影响这里的列表展示。
class RecentRecordsService {
  RecentRecordsService({
    required this.books,
    required this.progress,
    required this.daos,
    required this.kv,
  });

  static const clearedKey = 'recent_records_cleared_at';

  final ReaderBookStore books;
  final ReaderProgressStore progress;
  final Daos daos;
  final KeyValueStore kv;

  /// 合并阅读与听书记录，按最近时间倒序，最多 [max] 条。
  ///
  /// [ignoreCleared] 为 true 时忽略「清空」时间戳（书架续读条使用：
  /// 清空记录不应让续读条消失）。
  List<RecentRecord> build({int max = 8, bool ignoreCleared = false}) {
    final clearedAt = ignoreCleared ? null : _clearedAt();
    final records = <RecentRecord>[
      ..._readingRecords(),
      ..._listeningRecords(),
    ];
    if (clearedAt != null) {
      records.removeWhere((r) => !r.at.isAfter(clearedAt));
    }
    records.sort((a, b) => b.at.compareTo(a.at));
    return records.take(max).toList();
  }

  /// 最近 1 条未读完的书 / 专辑（书架顶部续读条）。
  RecentRecord? latestUnfinished() {
    for (final record in build(max: 50, ignoreCleared: true)) {
      if (!record.finished) return record;
    }
    return null;
  }

  /// 只清空列表：写入时间戳后，旧记录被过滤，新活动会重新出现。
  Future<void> clear() =>
      kv.setString(clearedKey, DateTime.now().toIso8601String());

  DateTime? _clearedAt() {
    final raw = kv.getString(clearedKey);
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  List<RecentRecord> _readingRecords() {
    final result = <RecentRecord>[];
    for (final book in books.books) {
      final at = book.lastReadAt;
      if (at == null) continue;
      final saved = progress.read(book.id);
      result.add(RecentRecord(
        kind: RecentRecordKind.reading,
        id: book.id,
        title: book.title,
        at: at,
        badgeLabel: book.source.label,
        page: saved?.page,
        chapterNumber: book.lastChapterIndex + 1,
        finished: book.progressPercent >= 100,
      ));
    }
    return result;
  }

  List<RecentRecord> _listeningRecords() {
    final result = <RecentRecord>[];
    final seen = <String>{};
    for (final history in daos.playHistory.all()) {
      if (!seen.add(history.albumId)) continue;
      if (history.playedAt <= 0) continue;
      final album = daos.albums.get(history.albumId);
      final chapters = daos.chapters.byAlbum(history.albumId);
      final position = chapters.indexWhere((c) => c.id == history.chapterId);
      final chapterNumber = position >= 0
          ? chapters[position].index + 1
          : 0;
      final total = chapters.isNotEmpty
          ? chapters.length
          : (album?.chapterCount ?? 0);
      final finished = total > 0 &&
          daos.playHistory.finishedCount(history.albumId) >= total;
      result.add(RecentRecord(
        kind: RecentRecordKind.listening,
        id: history.albumId,
        title: album?.title ?? '未知专辑',
        at: DateTime.fromMillisecondsSinceEpoch(history.playedAt),
        coverUrl: album?.coverUrl ?? '',
        chapterNumber: chapterNumber,
        chapterId: history.chapterId,
        chapterPosition: position,
        positionSec: history.positionSec,
        finished: finished,
      ));
    }
    return result;
  }
}
