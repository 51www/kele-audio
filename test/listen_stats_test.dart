import 'package:flutter_test/flutter_test.dart';

import 'package:kele_audio/core/domain/records.dart';
import 'package:kele_audio/core/services/listen_stats.dart';

/// M5 收听摘要单测：play_log 聚合（今日/本周/累计）与时长格式化。
void main() {
  PlayLogEntry log(String date, int sec) =>
      PlayLogEntry(date: date, albumId: 'a', categoryId: 'rec', durationSec: sec);

  test('fromEntries：今日/本周（周一 00:00 起）/累计 三口径', () {
    final now = DateTime(2026, 10, 26, 15); // 周一
    final entries = [
      log('2026-10-26', 600), // 今天（也在本周）
      log('2026-10-26', 300), // 今天第二条（同天多专辑）
      log('2026-10-25', 1200), // 昨天 = 上周日，不进本周
      log('2026-10-22', 500), // 上周四，不进本周
      log('2026-10-01', 400), // 更早
    ];

    final s = ListenStats.fromEntries(entries, now: now);
    expect(s.todaySec, 900);
    expect(s.weekSec, 900); // 本周只有今天
    expect(s.totalSec, 3000);
  });

  test('fromEntries：本周含周一至今天的全部天', () {
    final now = DateTime(2026, 10, 28, 15); // 周三
    final entries = [
      log('2026-10-26', 100), // 周一
      log('2026-10-27', 200), // 周二
      log('2026-10-28', 400), // 周三（今天）
      log('2026-10-25', 800), // 上周日
    ];

    final s = ListenStats.fromEntries(entries, now: now);
    expect(s.todaySec, 400);
    expect(s.weekSec, 700);
    expect(s.totalSec, 1500);
  });

  test('fromEntries：非法日期行只计入累计，不误入口径', () {
    final now = DateTime(2026, 10, 26, 15);
    final entries = [log('bad-date', 100), log('2026-10-26', 50)];

    final s = ListenStats.fromEntries(entries, now: now);
    expect(s.totalSec, 150);
    expect(s.todaySec, 50);
  });

  test('fromEntries：空列表为零', () {
    final s = ListenStats.fromEntries(const [], now: DateTime(2026, 1, 1));
    expect(s.todaySec, 0);
    expect(s.weekSec, 0);
    expect(s.totalSec, 0);
  });

  test('formatDuration：<1 分钟、分钟、小时（整数/小数）', () {
    expect(ListenStats.formatDuration(0), '0 分钟');
    expect(ListenStats.formatDuration(45), '<1 分钟');
    expect(ListenStats.formatDuration(90), '2 分钟');
    expect(ListenStats.formatDuration(2520), '42 分钟');
    expect(ListenStats.formatDuration(3600), '1 小时');
    expect(ListenStats.formatDuration(5400), '1.5 小时');
    expect(ListenStats.formatDuration(40000), '11 小时');
  });
}
