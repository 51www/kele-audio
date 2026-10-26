import '../data/daos.dart';
import '../domain/records.dart';

/// 历史收听视图模型（M5，PRD §5.6.2）。
///
/// `play_history` 是章节级（每章一行），历史页按 PRD 列表字段
/// （封面、标题、最后播放章节与进度、时间）做**专辑级聚合**：
/// 每专辑一行，代表记录 = 该专辑 playedAt 最新的一行。
class HistoryEntryView {
  const HistoryEntryView({
    required this.albumId,
    required this.title,
    required this.coverUrl,
    required this.upName,
    required this.lastChapterId,
    required this.lastChapterTitle,
    required this.lastPositionSec,
    required this.lastDurationSec,
    required this.playedAt,
  });

  final String albumId;
  final String title;
  final String coverUrl;
  final String upName;

  /// 最后播放章节与秒级进度
  final String lastChapterId;
  final String lastChapterTitle;
  final int lastPositionSec;
  final int lastDurationSec;

  /// 最近收听时间（毫秒时间戳）
  final int playedAt;

  /// 最后播放章节的进度百分比（0~100）
  int get percent => lastDurationSec <= 0
      ? 0
      : (lastPositionSec * 100 / lastDurationSec).round().clamp(0, 100);
}

/// 按天分组的历史分组（今天 / 昨天 / 日期）。
class HistoryDayGroup {
  const HistoryDayGroup({required this.label, required this.entries});

  /// `今天` / `昨天` / `10 月 24 日` / `2025 年 12 月 3 日`
  final String label;
  final List<HistoryEntryView> entries;
}

/// 历史页用例服务：`play_history`（× `album`）聚合 + 删除 / 撤销 / 清空。
class HistoryService {
  HistoryService(this._daos);

  final Daos _daos;

  /// 专辑级聚合（纯同步读内存表，UI 每次 build 调用即为刷新）。
  List<HistoryEntryView> buildEntries() {
    // all() 已按 playedAt 降序 → putIfAbsent 首次命中即该专辑最新记录
    final rows = _daos.playHistory.all();
    final byAlbum = <String, PlayHistory>{};
    for (final r in rows) {
      byAlbum.putIfAbsent(r.albumId, () => r);
    }
    return [for (final r in byAlbum.values) _viewOf(r)]
      ..sort((a, b) => b.playedAt.compareTo(a.playedAt));
  }

  HistoryEntryView _viewOf(PlayHistory row) {
    final album = _daos.albums.get(row.albumId);
    return HistoryEntryView(
      albumId: row.albumId,
      title: album?.title ?? '未知专辑',
      coverUrl: album?.coverUrl ?? '',
      upName: album?.upName ?? '',
      lastChapterId: row.chapterId,
      lastChapterTitle: row.chapterTitle,
      lastPositionSec: row.positionSec,
      lastDurationSec: row.durationSec,
      playedAt: row.playedAt,
    );
  }

  /// 按天分组（组间新→旧，组内新→旧）。纯函数，单测直接构造。
  static List<HistoryDayGroup> groupByDay(
    List<HistoryEntryView> entries, {
    DateTime? now,
  }) {
    final n = now ?? DateTime.now();

    final order = <String>[];
    final buckets = <String, List<HistoryEntryView>>{};
    for (final e in entries) {
      final d = DateTime.fromMillisecondsSinceEpoch(e.playedAt);
      final day = DateTime(d.year, d.month, d.day);
      final key = dayLabel(day, now: n);
      if (buckets.containsKey(key)) {
        buckets[key]!.add(e);
      } else {
        order.add(key);
        buckets[key] = [e];
      }
    }
    return [
      for (final key in order)
        HistoryDayGroup(
          label: key,
          entries: (buckets[key] ?? const [])
            ..sort((a, b) => b.playedAt.compareTo(a.playedAt)),
        ),
    ];
  }

  /// 分组标题：今天 / 昨天 / 同年 `10 月 24 日` / 跨年 `2025 年 12 月 3 日`。
  static String dayLabel(DateTime day, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    final d = DateTime(day.year, day.month, day.day);
    if (d == today) return '今天';
    if (d == today.subtract(const Duration(days: 1))) return '昨天';
    if (d.year == n.year) return '${d.month} 月 ${d.day} 日';
    return '${d.year} 年 ${d.month} 月 ${d.day} 日';
  }

  /// 单条删除：清掉该专辑的**全部**历史行；返回被删行供「撤销」。
  Future<List<PlayHistory>> removeAlbum(String albumId) async {
    final rows = _daos.playHistory.forAlbum(albumId);
    await _daos.playHistory.removeAlbum(albumId);
    return rows;
  }

  /// 撤销删除：整批写回（主键 albumId|chapterId，幂等）。
  Future<void> restore(List<PlayHistory> rows) async {
    for (final r in rows) {
      await _daos.playHistory.put(r);
    }
  }

  /// 清空全部历史（确认弹层后调用）。
  Future<void> clear() => _daos.playHistory.clear();
}
