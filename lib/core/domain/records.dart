/// 本地持久化记录：书架 / 播放历史 / 播放日志 / 下载（PRD §7.5）。
library;

/// `shelf`：收藏（仅存本地，无账号同步）。
class ShelfItem {
  const ShelfItem({
    required this.albumId,
    required this.createdAt,
    this.lastChapterId = '',
    this.lastPositionSec = 0,
    this.lastPlayedAt = 0,
    this.finishedChapters = 0,
    this.totalChapters = 0,
  });

  final String albumId;
  final int createdAt;

  /// 最后收听的章节与秒级进度（P-04 跨章续播用）
  final String lastChapterId;
  final int lastPositionSec;
  final int lastPlayedAt;
  final int finishedChapters;

  /// 专辑总章节数（书架卡片「已听 12/86」的分母）
  final int totalChapters;

  Map<String, dynamic> toJson() => {
        'album_id': albumId,
        'created_at': createdAt,
        'last_chapter_id': lastChapterId,
        'last_position_sec': lastPositionSec,
        'last_played_at': lastPlayedAt,
        'finished_chapters': finishedChapters,
        'total_chapters': totalChapters,
      };

  factory ShelfItem.fromJson(Map<String, dynamic> j) => ShelfItem(
        albumId: '${j['album_id'] ?? ''}',
        createdAt: (j['created_at'] as num?)?.toInt() ?? 0,
        lastChapterId: '${j['last_chapter_id'] ?? ''}',
        lastPositionSec: (j['last_position_sec'] as num?)?.toInt() ?? 0,
        lastPlayedAt: (j['last_played_at'] as num?)?.toInt() ?? 0,
        finishedChapters: (j['finished_chapters'] as num?)?.toInt() ?? 0,
        totalChapters: (j['total_chapters'] as num?)?.toInt() ?? 0,
      );
}

/// `play_history`：断点续播与历史页数据源（P-03 / P-04）。
class PlayHistory {
  const PlayHistory({
    required this.albumId,
    required this.chapterId,
    required this.positionSec,
    required this.durationSec,
    required this.playedAt,
    this.chapterTitle = '',
  });

  final String albumId;
  final String chapterId;
  final int positionSec;
  final int durationSec;
  final int playedAt;
  final String chapterTitle;

  /// 进度百分比（0~100）
  int get percent => durationSec <= 0
      ? 0
      : (positionSec * 100 / durationSec).round().clamp(0, 100);

  Map<String, dynamic> toJson() => {
        'album_id': albumId,
        'chapter_id': chapterId,
        'position_sec': positionSec,
        'duration': durationSec,
        'played_at': playedAt,
        'chapter_title': chapterTitle,
      };

  factory PlayHistory.fromJson(Map<String, dynamic> j) => PlayHistory(
        albumId: '${j['album_id'] ?? ''}',
        chapterId: '${j['chapter_id'] ?? ''}',
        positionSec: (j['position_sec'] as num?)?.toInt() ?? 0,
        durationSec: (j['duration'] as num?)?.toInt() ?? 0,
        playedAt: (j['played_at'] as num?)?.toInt() ?? 0,
        chapterTitle: '${j['chapter_title'] ?? ''}',
      );
}

/// `play_log`：按天聚合的收听日志（M8 统计的数据源，M1 先建表埋口）。
class PlayLogEntry {
  const PlayLogEntry({
    required this.date,
    required this.albumId,
    required this.categoryId,
    required this.durationSec,
  });

  /// `yyyy-MM-dd`
  final String date;
  final String albumId;
  final String categoryId;
  final int durationSec;

  Map<String, dynamic> toJson() => {
        'date': date,
        'album_id': albumId,
        'category_id': categoryId,
        'duration_sec': durationSec,
      };

  factory PlayLogEntry.fromJson(Map<String, dynamic> j) => PlayLogEntry(
        date: '${j['date'] ?? ''}',
        albumId: '${j['album_id'] ?? ''}',
        categoryId: '${j['category_id'] ?? ''}',
        durationSec: (j['duration_sec'] as num?)?.toInt() ?? 0,
      );
}

/// 下载状态（离线缓存 M8 使用，M1 建表）。
enum DownloadStatus { queued, running, done, failed }

extension DownloadStatusX on DownloadStatus {
  String get wire => switch (this) {
        DownloadStatus.queued => 'queued',
        DownloadStatus.running => 'running',
        DownloadStatus.done => 'done',
        DownloadStatus.failed => 'failed',
      };

  static DownloadStatus fromWire(String? v) => switch (v) {
        'running' => DownloadStatus.running,
        'done' => DownloadStatus.done,
        'failed' => DownloadStatus.failed,
        _ => DownloadStatus.queued,
      };
}

/// `download`：离线索引（文件路径 + 大小 + 状态）。
class DownloadTask {
  const DownloadTask({
    required this.chapterId,
    required this.filePath,
    required this.sizeBytes,
    required this.status,
    this.albumId = '',
    this.updatedAt = 0,
    this.error = '',
  });

  final String chapterId;
  final String albumId;
  final String filePath;
  final int sizeBytes;
  final DownloadStatus status;
  final int updatedAt;

  /// 失败原因（status == failed 时有值；缓存页展示用，M8）。
  final String error;

  Map<String, dynamic> toJson() => {
        'chapter_id': chapterId,
        'album_id': albumId,
        'file_path': filePath,
        'size': sizeBytes,
        'status': status.wire,
        'updated_at': updatedAt,
        'error': error,
      };

  factory DownloadTask.fromJson(Map<String, dynamic> j) => DownloadTask(
        chapterId: '${j['chapter_id'] ?? ''}',
        albumId: '${j['album_id'] ?? ''}',
        filePath: '${j['file_path'] ?? ''}',
        sizeBytes: (j['size'] as num?)?.toInt() ?? 0,
        status: DownloadStatusX.fromWire('${j['status'] ?? ''}'),
        updatedAt: (j['updated_at'] as num?)?.toInt() ?? 0,
        error: '${j['error'] ?? ''}',
      );
}
