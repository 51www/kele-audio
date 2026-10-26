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
