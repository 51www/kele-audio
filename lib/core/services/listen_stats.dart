import '../domain/records.dart';

/// 收听时长摘要（M5「我的」页顶部三卡；完整统计 M8）。
///
/// 数据源：`play_log` 按天埋点（date / albumId / durationSec）。
/// 纯数据 + 纯函数，不依赖 Flutter，单测直接构造。
class ListenStats {
  const ListenStats({
    required this.todaySec,
    required this.weekSec,
    required this.totalSec,
  });

  static const zero = ListenStats(todaySec: 0, weekSec: 0, totalSec: 0);

  /// 今日收听秒数
  final int todaySec;

  /// 本周收听秒数（自然周，周一 00:00 起）
  final int weekSec;

  /// 累计收听秒数
  final int totalSec;

  /// 聚合 [PlayLogEntry] 列表；[now] 可注入便于测试。
  static ListenStats fromEntries(List<PlayLogEntry> entries, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    final weekStart = today.subtract(Duration(days: today.weekday - 1));

    var todaySec = 0;
    var weekSec = 0;
    var totalSec = 0;
    for (final e in entries) {
      totalSec += e.durationSec;
      final day = _parseDay(e.date);
      if (day == null) continue;
      if (!day.isBefore(today)) todaySec += e.durationSec;
      if (!day.isBefore(weekStart)) weekSec += e.durationSec;
    }
    return ListenStats(
      todaySec: todaySec,
      weekSec: weekSec,
      totalSec: totalSec,
    );
  }

  /// `yyyy-MM-dd` → 当天 00:00；解析失败返回 null。
  static DateTime? _parseDay(String date) {
    final d = DateTime.tryParse(date);
    return d == null ? null : DateTime(d.year, d.month, d.day);
  }

  /// 时长展示：< 1 分钟「<1 分钟」，< 1 小时「42 分钟」，
  /// ≥ 1 小时「1.5 小时」（≥ 10 小时取整）。
  static String formatDuration(int sec) {
    if (sec <= 0) return '0 分钟';
    if (sec < 60) return '<1 分钟';
    if (sec < 3600) return '${(sec / 60).round()} 分钟';
    final h = sec / 3600;
    final text = h >= 10 ? h.toStringAsFixed(0) : h.toStringAsFixed(1);
    return '${text.replaceAll(RegExp(r'\.0$'), '')} 小时';
  }
}

/// M8 统计页的扩展聚合（PRD §5.6.1）。
///
/// 数据源仍是 `play_log`（按天·专辑聚合），专辑/分类名由调用方
/// （页面）从 `album` 表与内容配置反查后传入。
class StatsAgg {
  StatsAgg._();

  /// 最近 N 天每日收听秒数（含今天，缺数据补 0；旧数据不在窗口内忽略）。
  static List<({String date, int sec})> dailyTrend(
    List<PlayLogEntry> entries, {
    required int days,
    DateTime? now,
  }) {
    final n = now ?? DateTime.now();
    final byDay = <String, int>{};
    for (final e in entries) {
      byDay[e.date] = (byDay[e.date] ?? 0) + e.durationSec;
    }
    final out = <({String date, int sec})>[];
    for (var i = days - 1; i >= 0; i--) {
      final d = DateTime(n.year, n.month, n.day - i);
      final key =
          '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
      out.add((date: key, sec: byDay[key] ?? 0));
    }
    return out;
  }

  /// 本月收听秒数。
  static int monthSec(List<PlayLogEntry> entries, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final prefix =
        '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}';
    return entries
        .where((e) => e.date.startsWith(prefix))
        .fold(0, (s, e) => s + e.durationSec);
  }

  /// 分类 Top（按累计秒数降序）；[nameOf] 反查分类显示名。
  static List<({String id, String name, int sec})> topCategories(
    List<PlayLogEntry> entries, {
    required String Function(String id) nameOf,
    int limit = 3,
  }) {
    final byCat = <String, int>{};
    for (final e in entries) {
      byCat[e.categoryId] = (byCat[e.categoryId] ?? 0) + e.durationSec;
    }
    final rows = byCat.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      for (final r in rows.take(limit))
        (
          id: r.key,
          name: nameOf(r.key),
          sec: r.value,
        ),
    ];
  }

  /// 专辑 Top（按累计秒数降序）；[nameOf] 反查专辑标题。
  static List<({String id, String name, int sec})> topAlbums(
    List<PlayLogEntry> entries, {
    required String Function(String id) nameOf,
    int limit = 5,
  }) {
    final byAlbum = <String, int>{};
    for (final e in entries) {
      byAlbum[e.albumId] = (byAlbum[e.albumId] ?? 0) + e.durationSec;
    }
    final rows = byAlbum.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      for (final r in rows.take(limit))
        (
          id: r.key,
          name: nameOf(r.key),
          sec: r.value,
        ),
    ];
  }

  /// 累计听完专辑数：专辑下「已听完章节数（percent≥90%）」≥ 专辑章节数
  /// （章节数取 album 表；无章节数据的专辑不计入）。
  static int finishedAlbumCount({
    required int Function(String albumId) finishedChaptersOf,
    required int Function(String albumId) totalChaptersOf,
    required Iterable<String> albumIds,
  }) {
    var n = 0;
    for (final id in albumIds) {
      final total = totalChaptersOf(id);
      if (total > 0 && finishedChaptersOf(id) >= total) n++;
    }
    return n;
  }
}
