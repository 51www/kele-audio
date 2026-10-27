import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:kele_audio/core/api/content_config.dart';
import 'package:kele_audio/core/api/discover_source.dart';
import 'package:kele_audio/core/api/key_value_store.dart';
import 'package:kele_audio/core/data/discover_cache.dart';
import 'package:kele_audio/core/domain/album.dart';

/// M3 单元测试：内容配置解析 / 过滤与时长解析 / 搜索与合集实体转换 /
/// 分类首页缓存（TTL、过期兜底、损坏容错）。
void main() {
  CategoryConfig audioCat() => CategoryConfig(
        id: 'rec',
        name: '推荐',
        filter: CategoryConfig.filterAudio,
        minDurationSec: 300,
        queries: const [],
      );

  CategoryConfig plainCat() => CategoryConfig(
        id: 'music',
        name: '音乐',
        filter: CategoryConfig.filterPlain,
        minDurationSec: 180,
        queries: const [],
      );

  group('时长解析（B 站 mm:ss / h:mm:ss，分钟位不限宽）', () {
    test('常规与超长', () {
      expect(DiscoverSource.parseDurationSeconds('1:44'), 104);
      expect(DiscoverSource.parseDurationSeconds('16:52'), 1012);
      expect(DiscoverSource.parseDurationSeconds('0:58'), 58);
      // 实测样本：《凡人修仙传》有声剧 25724 分 11 秒
      expect(DiscoverSource.parseDurationSeconds('25724:11'), 1543451);
      expect(DiscoverSource.parseDurationSeconds('1:02:03'), 3723);
      expect(DiscoverSource.parseDurationSeconds(''), 0);
      expect(DiscoverSource.parseDurationSeconds('x:3'), 0);
    });
  });

  group('内容过滤', () {
    test('audio：听书信号正向命中', () {
      // 标题含听书特征词（≥300s）
      expect(
        DiscoverSource.passesFilter(
          title: '有声书《十日终焉》全集，多人小说剧',
          durationSec: 13270 * 60 + 50,
          typeid: 195,
          tag: '有声,小说',
          upName: '某UP',
          category: audioCat(),
        ),
        isTrue,
      );
      // 相声长合集（标题特征词）
      expect(
        DiscoverSource.passesFilter(
          title: '郭德纲&于谦相声集',
          durationSec: 2501 * 60 + 33,
          typeid: 71,
          tag: '相声',
          upName: '德云社',
          category: audioCat(),
        ),
        isTrue,
      );
      // 195 听书分区 ≥600s
      expect(
        DiscoverSource.passesFilter(
          title: '某某全集',
          durationSec: 700,
          typeid: 195,
          tag: '',
          upName: '',
          category: audioCat(),
        ),
        isTrue,
      );
      // 标题无信号但标签有（≥1800s）
      expect(
        DiscoverSource.passesFilter(
          title: '某某全集',
          durationSec: 2000,
          typeid: 228,
          tag: '有声小说,修仙',
          upName: '',
          category: audioCat(),
        ),
        isTrue,
      );
    });

    test('audio：噪音词一票否决 / 无信号长视频拒收', () {
      expect(
        DiscoverSource.passesFilter(
          title: '搞笑鬼畜混剪合集',
          durationSec: 3600,
          typeid: 195,
          tag: '有声',
          upName: '',
          category: audioCat(),
        ),
        isFalse,
      );
      // 30 分钟的普通视频，无任何听书信号 → 拒
      expect(
        DiscoverSource.passesFilter(
          title: '某纪录片',
          durationSec: 3000,
          typeid: 228,
          tag: '纪录片',
          upName: '某UP',
          category: audioCat(),
        ),
        isFalse,
      );
      // 时长不到地板 → 拒
      expect(
        DiscoverSource.passesFilter(
          title: '有声小说试听',
          durationSec: 120,
          typeid: 195,
          tag: '',
          upName: '',
          category: audioCat(),
        ),
        isFalse,
      );
    });

    test('plain：只看时长 + 轻噪音', () {
      expect(
        DiscoverSource.passesFilter(
          title: '钢琴曲合集',
          durationSec: 600,
          typeid: 267,
          tag: '音乐',
          upName: '',
          category: plainCat(),
        ),
        isTrue,
      );
      expect(
        DiscoverSource.passesFilter(
          title: '钢琴曲合集',
          durationSec: 100,
          typeid: 267,
          tag: '音乐',
          upName: '',
          category: plainCat(),
        ),
        isFalse,
      );
      expect(
        DiscoverSource.passesFilter(
          title: '沙雕动画合集',
          durationSec: 600,
          typeid: 267,
          tag: '音乐',
          upName: '',
          category: plainCat(),
        ),
        isFalse,
      );
    });
  });

  group('搜索结果 → 专辑（真实样本 shape，见 tool/spike/m3_shape_result.json）', () {
    test('字段解析：HTML 去除 / 封面协议补全 / videos 虚标容错', () {
      final album = DiscoverSource.albumFromSearch({
        'bvid': 'BV1714y1a7ww',
        'title': '多人<em class="keyword">有声</em>剧 |《凡人修仙传》忘语著 完结',
        'pic': '//i1.hdslb.com/bfs/archive/2cdb050c.jpg',
        'author': 'SimpleLifeT',
        'mid': '688151637',
        'videos': 'null', // 实测为字符串 "null"
        'duration': '25724:11',
        'play': '20135253',
        'pubdate': '1664340276',
        'typeid': '168',
        'description': '简介<b>加粗</b>',
      });
      expect(album, isNotNull);
      expect(album!.id, 'BV1714y1a7ww');
      expect(album.sourceType, SourceType.multiPart);
      expect(album.bvid, 'BV1714y1a7ww');
      expect(album.title, '多人有声剧 |《凡人修仙传》忘语著 完结');
      expect(album.coverUrl, 'https://i1.hdslb.com/bfs/archive/2cdb050c.jpg');
      expect(album.upName, 'SimpleLifeT');
      expect(album.upMid, 688151637);
      expect(album.chapterCount, 0); // "null" → 0，卡片不显示集数
      expect(album.totalDurationSec, 1543451);
      expect(album.playCount, 20135253);
      expect(album.createdAt, 1664340276 * 1000);
      expect(album.intro, '简介加粗');
    });

    test('bvid / 标题为空 → null', () {
      expect(DiscoverSource.albumFromSearch({'title': 'x'}), isNull);
      expect(DiscoverSource.albumFromSearch({'bvid': 'BV1'}), isNull);
    });
  });

  group('合集 meta → 专辑卡片（实测：无 up_name / upmid 用 mid）', () {
    test('season 卡片', () {
      final album = DiscoverSource.albumFromCollectionMeta(
        {
          'category': 0,
          'cover': 'https://archive.biliimg.com/bfs/archive/3519.jpg',
          'description': '',
          'mid': 19566500,
          'name': '合集·【十日终焉】我来自终焉之地',
          'ptime': 1788321147,
          'season_id': 1683170,
          'total': 60,
          'title': '【十日终焉】我来自终焉之地',
        },
        isSeason: true,
        categoryId: 'xiaoshuo',
      );
      expect(album.id, 'season:1683170');
      expect(album.sourceType, SourceType.series);
      expect(album.title, '【十日终焉】我来自终焉之地');
      expect(album.chapterCount, 60); // meta.total 而非首页条数
      expect(album.upMid, 19566500); // meta['upmid'] 缺失时回落 meta['mid']
      expect(album.categoryId, 'xiaoshuo');
      expect(album.createdAt, 1788321147 * 1000);
    });

    test('series 卡片（meta 无 id，用外部传入）', () {
      final album = DiscoverSource.albumFromCollectionMeta(
        {'cover': '', 'mid': 3493285641823557, 'name': '德云社合集', 'total': 24},
        isSeason: false,
        seriesId: 132528,
      );
      expect(album.id, 'series:132528');
      expect(album.upMid, 3493285641823557);
      expect(album.chapterCount, 24);
    });
  });

  group('内容配置', () {
    test('内置兜底：7 个成人分类', () {
      final config = ContentConfig.builtIn();
      final cats = config.adultCategories;
      expect(cats.map((c) => c.id).toList(),
          ['rec', 'xiaoshuo', 'xiangsheng', 'jiangshu', 'music', 'boke', 'yingyu']);
      expect(config.byId('music')!.minDurationSec, 180);
      expect(config.byId('xiangshu'), isNull);
    });

    test('随包 JSON 可解析且与内置一致（R1 下发基线）', () {
      final raw = File('assets/api/content_config.json').readAsStringSync();
      final config = ContentConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      expect(config.cacheTtlMinutes, 30);
      expect(
        config.adultCategories.map((c) => c.id).toList(),
        ContentConfig.builtIn().adultCategories.map((c) => c.id).toList(),
      );
      // 有声书分类：合集优先 + 搜索补充
      final xiaoshuo = config.byId('xiaoshuo')!;
      expect(xiaoshuo.queries.first.source, QuerySource.series);
      expect(
        xiaoshuo.queries.where((q) => q.source == QuerySource.search).length,
        2,
      );
    });

    test('加载器：内置 → 静默回退（损坏 JSON 不炸）', () async {
      final kv = MemoryKeyValueStore();
      final ok = await ContentConfigLoader.load(
        store: kv,
        bundledJson: () async =>
            File('assets/api/content_config.json').readAsStringSync(),
      );
      expect(ok.adultCategories.length, 7);

      final broken = await ContentConfigLoader.load(
        store: kv,
        bundledJson: () async => '{broken',
      );
      expect(broken.adultCategories.length, 7); // 回退内置
    });
  });

  group('分类首页缓存（TTL 30min + 断网兜底）', () {
    List<Album> sample() => [
          DiscoverSource.albumFromSearch({
            'bvid': 'BV1',
            'title': '专辑一',
            'pic': '//x/1.jpg',
            'author': 'UP1',
            'duration': '10:00',
            'play': '100',
          })!,
        ];

    test('新鲜命中 / 过期拒收 / allowStale 兜底', () async {
      var now = DateTime(2026, 1, 1, 12);
      final kv = MemoryKeyValueStore();
      final cache = DiscoverPageCache(kv, now: () => now);

      await cache.save('rec', items: sample(), hasMore: true);
      final fresh = cache.read('rec', ttl: const Duration(minutes: 30));
      expect(fresh, isNotNull);
      expect(fresh!.stale, isFalse);
      expect(fresh.hasMore, isTrue);
      expect(fresh.items.first.id, 'BV1');

      now = now.add(const Duration(minutes: 31));
      expect(cache.read('rec', ttl: const Duration(minutes: 30)), isNull);
      final stale =
          cache.read('rec', ttl: const Duration(minutes: 30), allowStale: true);
      expect(stale, isNotNull);
      expect(stale!.stale, isTrue);

      // 未命中
      expect(cache.read('music', ttl: const Duration(minutes: 30)), isNull);
    });

    test('损坏缓存视为未命中', () async {
      final kv = MemoryKeyValueStore();
      await kv.setString('discover_cache:rec', 'not-json{');
      final cache = DiscoverPageCache(kv);
      expect(cache.read('rec'), isNull);
    });
  });
}
