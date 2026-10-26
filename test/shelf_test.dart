import 'package:flutter_test/flutter_test.dart';

import 'package:kele_audio/core/api/key_value_store.dart';
import 'package:kele_audio/core/data/daos.dart';
import 'package:kele_audio/core/data/local_database.dart';
import 'package:kele_audio/core/domain/album.dart';
import 'package:kele_audio/core/domain/records.dart';
import 'package:kele_audio/core/services/shelf_controller.dart';

/// M4 书架逻辑单测：shelf × album × play_history 联合查询。
///
/// 覆盖：已听章节数统计、总章节数回退、在听判定（30 天 + 未听完）、排序。
void main() {
  late LocalDatabase db;
  late Daos daos;
  late ShelfController shelf;

  setUp(() {
    db = LocalDatabase(MemoryKeyValueStore());
    daos = Daos(db);
    shelf = ShelfController(daos);
  });

  Album makeAlbum(String id, {int chapterCount = 10}) => Album(
        id: id,
        sourceType: SourceType.multiPart,
        title: '专辑 $id',
        coverUrl: 'https://example.com/$id.jpg',
        upName: 'UP $id',
        chapterCount: chapterCount,
        categoryId: 'rec',
      );

  Chapter makeChapter(String albumId, int index, {int cid = 1}) => Chapter(
        id: '$albumId:$cid$index',
        albumId: albumId,
        index: index,
        title: '第 $index 章',
        durationSec: 600,
        cid: cid + index,
      );

  PlayHistory makeHist(
    String albumId,
    String chapterId, {
    int pos = 600,
    int dur = 600,
    int playedAt = 0,
  }) =>
      PlayHistory(
        albumId: albumId,
        chapterId: chapterId,
        positionSec: pos,
        durationSec: dur,
        playedAt: playedAt,
        chapterTitle: '第',
      );

  test('收藏状态：toggle 增删 + has 反查', () async {
    await db.ensureCreated();
    expect(shelf.has('a1'), isFalse);
    await shelf.toggle('a1');
    expect(shelf.has('a1'), isTrue);
    await shelf.toggle('a1');
    expect(shelf.has('a1'), isFalse);
  });

  test('buildViews：已听章节数 = percent≥90 的章节数', () async {
    await db.ensureCreated();
    await daos.albums.upsert(makeAlbum('a1', chapterCount: 5));
    for (var i = 0; i < 5; i++) {
      await daos.chapters.upsertAll([makeChapter('a1', i)]);
    }
    // 3 章听完（100%），2 章在听（50%）
    await daos.playHistory.put(makeHist('a1', 'a1:1${0}', pos: 600, dur: 600));
    await daos.playHistory.put(makeHist('a1', 'a1:1${1}', pos: 600, dur: 600));
    await daos.playHistory.put(makeHist('a1', 'a1:1${2}', pos: 600, dur: 600));
    await daos.playHistory.put(makeHist('a1', 'a1:1${3}', pos: 300, dur: 600));
    await daos.playHistory.put(makeHist('a1', 'a1:1${4}', pos: 300, dur: 600));

    // 加入书架（记录 lastPlayedAt / totalChapters 由播放时 touch 写入，
    // 这里直接 upsert 一个带进度的 shelf item 模拟播放过）
    await daos.shelf.upsertItem(ShelfItem(
      albumId: 'a1',
      createdAt: 1000,
      lastChapterId: 'a1:1${4}',
      lastPositionSec: 300,
      lastPlayedAt: DateTime.now().millisecondsSinceEpoch,
      finishedChapters: 0,
      totalChapters: 5,
    ));
    await shelf.ensure();

    final views = shelf.buildViews();
    expect(views.length, 1);
    final v = views.first;
    expect(v.finishedCount, 3); // 3 章听完
    expect(v.totalChapters, 5);
    expect(v.lastChapterPercent, 50); // 最后一章 300/600
  });

  test('buildViews：总章节数回退到专辑 chapterCount', () async {
    await db.ensureCreated();
    await daos.albums.upsert(makeAlbum('a2', chapterCount: 8));
    await daos.shelf.upsertItem(ShelfItem(
      albumId: 'a2',
      createdAt: 1000,
      totalChapters: 0, // shelf 没记到总章节数
    ));
    await shelf.ensure();
    final v = shelf.buildViews().first;
    expect(v.totalChapters, 8); // 回退专辑 chapterCount
    expect(v.inListening, isFalse); // 没有播放记录
  });

  test('buildViews：在听判定 = 30 天内播放且未听完', () async {
    await db.ensureCreated();
    await daos.albums.upsert(makeAlbum('a3', chapterCount: 10));

    // 31 天前播放过、听完 → 不在听
    await daos.shelf.upsertItem(ShelfItem(
      albumId: 'a3',
      createdAt: 1000,
      lastChapterId: 'a3:x',
      lastPositionSec: 0,
      lastPlayedAt: DateTime.now()
          .subtract(const Duration(days: 31))
          .millisecondsSinceEpoch,
      totalChapters: 10,
    ));
    await daos.playHistory.put(makeHist('a3', 'a3:x',
        pos: 600, dur: 600, playedAt: 1)); // 听完
    await shelf.ensure();
    expect(shelf.buildViews().first.inListening, isFalse);

    // 今天播放过、未听完 → 在听
    await daos.shelf.upsertItem(ShelfItem(
      albumId: 'a3',
      createdAt: 1000,
      lastChapterId: 'a3:y',
      lastPositionSec: 100,
      lastPlayedAt: DateTime.now().millisecondsSinceEpoch,
      totalChapters: 10,
    ));
    await daos.playHistory.put(makeHist('a3', 'a3:y',
        pos: 100, dur: 600, playedAt: 2)); // 未听完
    await shelf.ensure();
    expect(shelf.buildViews().first.inListening, isTrue);
  });

  test('removeAll / restore：批量删除与撤销', () async {
    await db.ensureCreated();
    await daos.albums.upsert(makeAlbum('a1'));
    await daos.albums.upsert(makeAlbum('a2'));
    final item = ShelfItem(albumId: 'a1', createdAt: 1, totalChapters: 5);
    await daos.shelf.upsertItem(item);
    await daos.shelf.upsertItem(ShelfItem(albumId: 'a2', createdAt: 2));
    await shelf.ensure();
    expect(shelf.buildViews().length, 2);

    await shelf.removeAll(['a1', 'a2']);
    expect(shelf.has('a1'), isFalse);
    expect(shelf.has('a2'), isFalse);
    expect(shelf.buildViews().length, 0);

    await shelf.restore(item); // 撤销 a1，保留进度字段
    expect(shelf.has('a1'), isTrue);
    expect(shelf.buildViews().first.totalChapters, 5);
  });
}
