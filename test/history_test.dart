import 'package:flutter_test/flutter_test.dart';

import 'package:kele_audio/core/api/key_value_store.dart';
import 'package:kele_audio/core/data/daos.dart';
import 'package:kele_audio/core/data/local_database.dart';
import 'package:kele_audio/core/domain/album.dart';
import 'package:kele_audio/core/domain/records.dart';
import 'package:kele_audio/core/services/history_service.dart';

/// M5 历史收听单测：专辑级聚合、今天/昨天/日期分组、删除/撤销/清空。
void main() {
  late LocalDatabase db;
  late Daos daos;
  late HistoryService history;

  setUp(() {
    db = LocalDatabase(MemoryKeyValueStore());
    daos = Daos(db);
    history = HistoryService(daos);
  });

  Album makeAlbum(String id, String title) => Album(
        id: id,
        sourceType: SourceType.multiPart,
        title: title,
        coverUrl: 'https://example.com/$id.jpg',
        upName: 'UP $id',
        chapterCount: 5,
        categoryId: 'rec',
      );

  PlayHistory makeHist(
    String albumId,
    String chapterId, {
    int pos = 100,
    int dur = 200,
    int playedAt = 0,
    String chapterTitle = '',
  }) =>
      PlayHistory(
        albumId: albumId,
        chapterId: chapterId,
        positionSec: pos,
        durationSec: dur,
        playedAt: playedAt,
        chapterTitle: chapterTitle,
      );

  test('专辑级聚合：同专辑多章只出一条，代表记录 = playedAt 最新', () async {
    await db.ensureCreated();
    await daos.albums.upsert(makeAlbum('a1', '专辑甲'));
    await daos.playHistory.put(makeHist('a1', 'a1:c1',
        pos: 10, playedAt: 1000, chapterTitle: '第一章'));
    await daos.playHistory.put(makeHist('a1', 'a1:c2',
        pos: 150, playedAt: 5000, chapterTitle: '第二章'));
    await daos.playHistory.put(makeHist('a1', 'a1:c3',
        pos: 60, playedAt: 3000, chapterTitle: '第三章'));

    final entries = history.buildEntries();
    expect(entries, hasLength(1));
    expect(entries.first.lastChapterTitle, '第二章');
    expect(entries.first.playedAt, 5000);
    expect(entries.first.percent, 75); // 150/200
    expect(entries.first.title, '专辑甲');
    expect(entries.first.coverUrl, 'https://example.com/a1.jpg');
  });

  test('多专辑按 playedAt 新→旧排序', () async {
    await db.ensureCreated();
    await daos.albums.upsert(makeAlbum('a1', '甲'));
    await daos.albums.upsert(makeAlbum('a2', '乙'));
    await daos.playHistory
        .put(makeHist('a1', 'a1:c1', playedAt: 1000, chapterTitle: 'c'));
    await daos.playHistory
        .put(makeHist('a2', 'a2:c1', playedAt: 9000, chapterTitle: 'c'));

    final entries = history.buildEntries();
    expect(entries.map((e) => e.albumId), ['a2', 'a1']);
  });

  test('专辑缺失时兜底标题/空封面（不抛异常）', () async {
    await db.ensureCreated();
    await daos.playHistory
        .put(makeHist('ghost', 'ghost:c1', playedAt: 1000));

    final entries = history.buildEntries();
    expect(entries.single.title, '未知专辑');
    expect(entries.single.coverUrl, isEmpty);
    expect(entries.single.upName, isEmpty);
  });

  test('分组：今天/昨天/日期分桶，组内新→旧', () async {
    final now = DateTime(2026, 10, 26, 15);
    final today = DateTime(2026, 10, 26, 9).millisecondsSinceEpoch;
    final todayLate = DateTime(2026, 10, 26, 11).millisecondsSinceEpoch;
    final yesterday = DateTime(2026, 10, 25, 20).millisecondsSinceEpoch;
    final older = DateTime(2026, 10, 23, 8).millisecondsSinceEpoch;

    final entries = [
      HistoryEntryView(
        albumId: 'a', title: '甲', coverUrl: '', upName: '',
        lastChapterId: '', lastChapterTitle: '', lastPositionSec: 0,
        lastDurationSec: 100, playedAt: today,
      ),
      HistoryEntryView(
        albumId: 'b', title: '乙', coverUrl: '', upName: '',
        lastChapterId: '', lastChapterTitle: '', lastPositionSec: 0,
        lastDurationSec: 100, playedAt: yesterday,
      ),
      HistoryEntryView(
        albumId: 'c', title: '丙', coverUrl: '', upName: '',
        lastChapterId: '', lastChapterTitle: '', lastPositionSec: 0,
        lastDurationSec: 100, playedAt: todayLate,
      ),
      HistoryEntryView(
        albumId: 'd', title: '丁', coverUrl: '', upName: '',
        lastChapterId: '', lastChapterTitle: '', lastPositionSec: 0,
        lastDurationSec: 100, playedAt: older,
      ),
    ];

    final groups = HistoryService.groupByDay(entries, now: now);
    expect(groups.map((g) => g.label), ['今天', '昨天', '10 月 23 日']);
    expect(groups[0].entries.map((e) => e.albumId), ['c', 'a']); // 组内新→旧
    expect(groups[1].entries.single.albumId, 'b');
    expect(groups[2].entries.single.albumId, 'd');
  });

  test('dayLabel：今天/昨天/同年/跨年', () {
    final now = DateTime(2026, 10, 26, 12);
    expect(HistoryService.dayLabel(DateTime(2026, 10, 26), now: now), '今天');
    expect(HistoryService.dayLabel(DateTime(2026, 10, 25), now: now), '昨天');
    expect(
      HistoryService.dayLabel(DateTime(2026, 3, 5), now: now),
      '3 月 5 日',
    );
    expect(
      HistoryService.dayLabel(DateTime(2025, 12, 3), now: now),
      '2025 年 12 月 3 日',
    );
  });

  test('单条删除按专辑清历史，restore 整批撤销', () async {
    await db.ensureCreated();
    await daos.albums.upsert(makeAlbum('a1', '甲'));
    await daos.albums.upsert(makeAlbum('a2', '乙'));
    await daos.playHistory
        .put(makeHist('a1', 'a1:c1', playedAt: 1000, chapterTitle: 'x'));
    await daos.playHistory
        .put(makeHist('a1', 'a1:c2', playedAt: 2000, chapterTitle: 'y'));
    await daos.playHistory
        .put(makeHist('a2', 'a2:c1', playedAt: 3000, chapterTitle: 'z'));

    final removed = await history.removeAlbum('a1');
    expect(removed, hasLength(2)); // 返回被删行供撤销
    expect(daos.playHistory.forAlbum('a1'), isEmpty);
    expect(daos.playHistory.forAlbum('a2'), hasLength(1));

    await history.restore(removed);
    expect(daos.playHistory.forAlbum('a1'), hasLength(2));
    expect(history.buildEntries(), hasLength(2));
  });

  test('清空全部历史', () async {
    await db.ensureCreated();
    await daos.playHistory
        .put(makeHist('a1', 'a1:c1', playedAt: 1000, chapterTitle: 'x'));
    await daos.playHistory
        .put(makeHist('a2', 'a2:c1', playedAt: 2000, chapterTitle: 'y'));

    await history.clear();
    expect(history.buildEntries(), isEmpty);
    expect(daos.playHistory.count, 0);
  });

  test('percent：时长未知为 0，四舍五入并夹取 0~100', () {
    HistoryEntryView entry(int pos, int dur) => HistoryEntryView(
          albumId: 'a', title: '', coverUrl: '', upName: '',
          lastChapterId: '', lastChapterTitle: '',
          lastPositionSec: pos, lastDurationSec: dur, playedAt: 0,
        );
    expect(entry(50, 0).percent, 0); // 时长未知
    expect(entry(1, 3).percent, 33); // 33.3 → 33
    expect(entry(2, 3).percent, 67); // 66.7 → 67
    expect(entry(300, 100).percent, 100); // 夹取
    expect(entry(-10, 100).percent, 0); // 夹取
  });
}
