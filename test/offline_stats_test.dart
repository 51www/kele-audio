import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:kele_audio/core/api/album_source.dart';
import 'package:kele_audio/core/api/bili_client.dart';
import 'package:kele_audio/core/api/api_config.dart';
import 'package:kele_audio/core/api/content_config.dart';
import 'package:kele_audio/core/api/discover_source.dart';
import 'package:kele_audio/core/api/key_value_store.dart';
import 'package:kele_audio/core/api/play_url_service.dart';
import 'package:kele_audio/core/data/daos.dart';
import 'package:kele_audio/core/data/local_database.dart';
import 'package:kele_audio/core/domain/album.dart';
import 'package:kele_audio/core/domain/records.dart';
import 'package:kele_audio/core/services/listen_stats.dart';
import 'package:kele_audio/core/services/offline/audio_store.dart';
import 'package:kele_audio/core/services/offline/offline_cache_service.dart';

/// 内存音频存储替身。
class MemAudioStore implements AudioStore {
  final Map<String, List<int>> _data = {};

  @override
  Future<String> save(String key, List<int> bytes) async {
    _data[key] = bytes;
    return 'mem://$key';
  }

  @override
  Future<bool> delete(String key) async => _data.remove(key) != null;

  @override
  Future<String?> playableUrl(String key) async =>
      _data.containsKey(key) ? 'mem://$key' : null;

  @override
  Future<int> sizeOf(String key) async => _data[key]?.length ?? 0;

  @override
  Future<void> clearAll() async => _data.clear();

  @override
  String get locationLabel => 'mem';
}

/// M8 单元测试：离线缓存队列状态机、听书统计聚合、搜索过滤口径、精选配置。
void main() {
  group('离线缓存服务（队列状态机）', () {
    late LocalDatabase db;
    late MemoryKeyValueStore kv;
    late MemAudioStore audioStore;
    late OfflineCacheService service;
    late Daos daos;

    setUp(() async {
      kv = MemoryKeyValueStore();
      db = LocalDatabase(kv);
      await db.ensureCreated();
      audioStore = MemAudioStore();
      daos = Daos(db);
      service = OfflineCacheService(
        daos: daos,
        // cid=0 的章节会走 albumSource.resolveCid → client.get 抛错
        //（BiliClient 未 initLocal），仍快速失败标记 failed
        playUrl: PlayUrlService(
          client: BiliClient(config: ApiConfig.defaults(), kv: kv),
          config: ApiConfig.defaults(),
        ),
        albumSource: AlbumSource(
          client: BiliClient(config: ApiConfig.defaults(), kv: kv),
          config: ApiConfig.defaults(),
        ),
        store: audioStore,
        fetcher: _NoFetch(),
      );
      await service.initFlags(kv);
    });

    test('initFlags：onlyCached 开关持久化', () async {
      expect(service.onlyCached, isFalse);
      await service.setOnlyCached(true);
      expect(service.onlyCached, isTrue);
      expect(kv.getString(OfflineCacheService.keyOnlyCached), '1');
    });

    test('章节缺 cid → 标记 failed，不崩不阻塞（R8）', () async {
      final album = Album(
        id: 'a1',
        sourceType: SourceType.multiPart,
        title: '专辑一',
        coverUrl: '',
        upName: '',
        chapterCount: 1,
        categoryId: 'rec',
        bvid: 'BV1xx',
      );
      final chapter = Chapter(
        id: 'a1:c1',
        albumId: 'a1',
        index: 0,
        title: '第一章',
        durationSec: 100,
        bvid: 'BV1xx',
        cid: 0, // 缺 cid
      );
      await daos.albums.upsert(album);
      await daos.chapters.upsertAll([chapter]);

      await service.cacheAlbum(album, [chapter]);
      // 等待队列消费到终态（入队 → running → failed）
      DownloadTask task = daos.downloads.get('a1:c1')!;
      for (var i = 0;
          i < 160 &&
              task.status != DownloadStatus.failed &&
              task.status != DownloadStatus.done;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        task = daos.downloads.get('a1:c1')!;
      }
      expect(task.status, DownloadStatus.failed);
      // 失败不阻塞：再次入队重试不会抛异常
      await service.cacheAlbum(album, [chapter]);
      expect(daos.downloads.get('a1:c1'), isNotNull);
    });

    test('pauseAlbum：进行中任务回 queued，专辑标记暂停', () async {
      final album = Album(
        id: 'a2',
        sourceType: SourceType.multiPart,
        title: '专辑二',
        coverUrl: '',
        upName: '',
        chapterCount: 2,
        categoryId: 'rec',
        bvid: 'BV2',
      );
      final chapters = [
        Chapter(
          id: 'a2:c1',
          albumId: 'a2',
          index: 0,
          title: '第一章',
          durationSec: 100,
          bvid: 'BV2',
          cid: 0,
        ),
        Chapter(
          id: 'a2:c2',
          albumId: 'a2',
          index: 1,
          title: '第二章',
          durationSec: 100,
          bvid: 'BV2',
          cid: 0,
        ),
      ];
      await daos.albums.upsert(album);
      await daos.chapters.upsertAll(chapters);

      await service.pauseAlbum('a2');
      expect(service.isPaused('a2'), isTrue);
      await service.cacheAlbum(album, chapters);
      await service.resumeAlbum('a2');
      expect(service.isPaused('a2'), isFalse);
      // 全部章节已入队
      expect(service.tasksFor('a2').length, 2);
    });

    test('deleteAlbum：任务与字节一并清除', () async {
      final album = Album(
        id: 'a3',
        sourceType: SourceType.multiPart,
        title: '专辑三',
        coverUrl: '',
        upName: '',
        chapterCount: 1,
        categoryId: 'rec',
        bvid: 'BV3',
      );
      final chapter = Chapter(
        id: 'a3:c1',
        albumId: 'a3',
        index: 0,
        title: '第一章',
        durationSec: 100,
        bvid: 'BV3',
        cid: 0,
      );
      await daos.albums.upsert(album);
      await daos.chapters.upsertAll([chapter]);
      // 直接造一条 done 记录 + 字节
      await daos.downloads.upsert(DownloadTask(
        chapterId: 'a3:c1',
        albumId: 'a3',
        filePath: 'a3:c1',
        sizeBytes: 100,
        status: DownloadStatus.done,
        updatedAt: 0,
      ));
      await audioStore.save('a3:c1', List.filled(64, 1));

      await service.deleteAlbum('a3');
      expect(daos.downloads.get('a3:c1'), isNull);
      expect(await audioStore.playableUrl('a3:c1'), isNull);
      expect(service.totalBytes, 0);
    });
  });

  group('听书统计聚合（StatsAgg）', () {
    final now = DateTime(2026, 10, 26, 12); // 周一

    List<PlayLogEntry> entries() => [
          PlayLogEntry(
            date: '2026-10-26',
            albumId: 'a1',
            categoryId: 'rec',
            durationSec: 1800,
          ),
          PlayLogEntry(
            date: '2026-10-26',
            albumId: 'a2',
            categoryId: 'rec',
            durationSec: 600,
          ),
          PlayLogEntry(
            date: '2026-10-25',
            albumId: 'a1',
            categoryId: 'xiaoshuo',
            durationSec: 3600,
          ),
          PlayLogEntry(
            date: '2026-10-01',
            albumId: 'a3',
            categoryId: 'xiangsheng',
            durationSec: 7200,
          ),
          PlayLogEntry(
            date: '2026-09-15',
            albumId: 'a1',
            categoryId: 'rec',
            durationSec: 900,
          ),
        ];

    test('today/week/month 口径', () {
      final e = entries();
      final stats = ListenStats.fromEntries(e, now: now);
      expect(stats.todaySec, 2400);
      // 2026-10-26 是周一：本周窗口只含 26 日（25 日属上周日）
      expect(stats.weekSec, 2400);
      expect(StatsAgg.monthSec(e, now: now), 13200);
    });

    test('dailyTrend 补零、窗口正确', () {
      final trend = StatsAgg.dailyTrend(entries(), days: 3, now: now);
      expect(trend.length, 3);
      expect(trend[0].date, '2026-10-24');
      expect(trend[0].sec, 0);
      expect(trend[1].sec, 3600);
      expect(trend[2].sec, 2400);
    });

    test('Top 榜：分类与专辑', () {
      final e = entries();
      final cats = StatsAgg.topCategories(e, nameOf: (id) => id, limit: 3);
      expect(cats.first.id, 'xiangsheng'); // 7200
      expect(cats[1].id, 'xiaoshuo'); // 3600 > rec 3300
      final albums = StatsAgg.topAlbums(e, nameOf: (id) => id, limit: 5);
      expect(albums.first.id, 'a3'); // 7200
      expect(albums[1].id, 'a1'); // 1800+3600+900=6300
    });

    test('finishedAlbumCount：听完章节数 ≥ 总章节数', () {
      final n = StatsAgg.finishedAlbumCount(
        albumIds: ['a1', 'a2', 'a3'],
        finishedChaptersOf: (id) => switch (id) {
          'a1' => 10,
          'a2' => 2,
          _ => 0,
        },
        totalChaptersOf: (id) => switch (id) {
          'a1' => 10,
          'a2' => 5,
          _ => 0, // 无章节数据不计入
        },
      );
      expect(n, 1); // 只有 a1
    });
  });

  group('搜索过滤（filterSearch）', () {
    bool pass(String title, {int duration = 600}) =>
        DiscoverSource.passesFilter(
          title: title,
          durationSec: duration,
          typeid: 0,
          tag: '',
          upName: '',
          category: CategoryConfig(
            id: 'search',
            name: '搜索',
            filter: CategoryConfig.filterSearch,
            minDurationSec: 60,
            queries: const [],
          ),
        );

    test('用户主动意图优先：无听书信号也收', () {
      expect(pass('凡人修仙传 全集'), isTrue);
      expect(pass('郭德纲相声 2026'), isTrue);
    });

    test('噪音词与时长地板仍然生效', () {
      expect(pass('鬼畜全明星'), isFalse);
      expect(pass('太短了', duration: 30), isFalse);
    });
  });

  group('编辑精选配置（FeaturedTopic）', () {
    test('builtIn：≥3 个专题，keyword/title 非空', () {
      final f = ContentConfig.builtIn().featured;
      expect(f.length, greaterThanOrEqualTo(3));
      expect(f.every((t) => t.keyword.trim().isNotEmpty), isTrue);
      expect(f.every((t) => t.title.trim().isNotEmpty), isTrue);
    });

    test('assets/api/content_config.json 与 builtIn 专题一致', () {
      final raw = File('assets/api/content_config.json').readAsStringSync();
      final fromAsset = ContentConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      ).featured;
      expect(
        fromAsset.map((t) => t.title).toSet(),
        ContentConfig.builtIn().featured.map((t) => t.title).toSet(),
      );
    });

    test('fromJson/toJson 往返无损', () {
      const t = FeaturedTopic(
        title: 'T',
        subtitle: 'S',
        keyword: 'K',
        emoji: 'X',
      );
      final back = FeaturedTopic.fromJson(t.toJson());
      expect(back.title, t.title);
      expect(back.keyword, t.keyword);
      expect(back.emoji, t.emoji);
    });
  });
}

/// 永不应被调用的拉取器（防御：被调即测试失败）。
class _NoFetch implements AudioFetcher {
  @override
  Future<List<int>> fetchBytes({
    required String url,
    required Map<String, String> headers,
    String Function(String url)? proxyUrlFor,
    bool Function()? isCancelled,
  }) async {
    fail('fetchBytes 不应被调用（测试章节均缺 cid，应在取址前拒绝）');
  }
}
