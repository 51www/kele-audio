import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kele_audio/app/theme/app_theme.dart';
import 'package:kele_audio/app/theme/app_tokens.dart';
import 'package:kele_audio/app/theme/theme_controller.dart';
import 'package:kele_audio/core/api/content_config.dart';
import 'package:kele_audio/core/api/discover_source.dart';
import 'package:kele_audio/core/api/key_value_store.dart';

/// M6 单元测试：儿童白名单配置（内置/资产/远端覆盖缓存 key）、
/// 儿童内容过滤（正向特征词 + 成人词一票否决）、儿童主题与模式优先级。
void main() {
  CategoryConfig kidCat({int minDurationSec = 120}) => CategoryConfig(
        id: 'kid_test',
        name: '测试',
        mode: 'children',
        filter: CategoryConfig.filterChildren,
        minDurationSec: minDurationSec,
        queries: const [],
      );

  group('儿童白名单配置（PRD §7.3）', () {
    test('内置兜底：5 类 children 分类，filter/时长门槛齐备', () {
      final config = ContentConfig.childrenBuiltIn();
      final kids = config.childrenCategories;
      expect(kids.length, 5);
      expect(kids.every((c) => c.mode == 'children'), isTrue);
      expect(kids.every((c) => c.filter == CategoryConfig.filterChildren),
          isTrue);
      expect(
        kids.map((c) => c.name).toSet(),
        {'绘本', '儿歌', '童话', '睡前故事', '科普'},
      );
      // 成人分类不受儿童配置影响
      expect(config.adultCategories, isEmpty);
      // 儿歌时长门槛最低（60s），其余 120s
      expect(
        kids.firstWhere((c) => c.name == '儿歌').minDurationSec,
        60,
      );
    });

    test('assets/api/children_config.json 与内置兜底同构（id/name 一致）', () {
      final raw =
          File('assets/api/children_config.json').readAsStringSync();
      final config = ContentConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      final assetIds = config.childrenCategories.map((c) => c.id).toSet();
      final builtInIds =
          ContentConfig.childrenBuiltIn().childrenCategories.map((c) => c.id);
      expect(assetIds, builtInIds.toSet());
      expect(config.childrenCategories.every((c) => c.mode == 'children'),
          isTrue);
    });

    test('loader：配置损坏 → 回退儿童内置兜底，不阻塞', () async {
      final config = await ContentConfigLoader.load(
        store: MemoryKeyValueStore(),
        bundledJson: () async => '{broken json',
        builtIn: ContentConfig.childrenBuiltIn,
        cacheKey: ContentConfigLoader.childrenRemoteCacheKey,
      );
      expect(config.childrenCategories.length, 5);
    });

    test('loader：儿童配置走独立缓存 key，不与成人配置串线', () async {
      final store = MemoryKeyValueStore();
      final remoteJson = jsonEncode({
        'version': 2,
        'remote_config_url': 'https://example.test/children.json',
        'categories': [
          {
            'category_id': 'kid_remote',
            'name': '远端儿童类',
            'mode': 'children',
            'filter': 'children',
            'min_duration_sec': 90,
            'queries': [
              {'source': 'search', 'keyword': '儿童故事'}
            ],
          },
        ],
      });
      final remoteMap = jsonDecode(remoteJson) as Map<String, dynamic>;
      // 内置兜底必须带远端地址才会启用「缓存/远端覆盖」链路
      ContentConfig builtInWithRemote() => ContentConfig(
            remoteConfigUrl: 'https://example.test/children.json',
            categories: ContentConfig.childrenBuiltIn().categories,
          );
      // 手动预置缓存（带未过期 fetched_at）：命中后直接用远端儿童配置，
      // 不触发真实网络请求
      await store.setString(
        ContentConfigLoader.childrenRemoteCacheKey,
        jsonEncode({
          'fetched_at': DateTime.now().millisecondsSinceEpoch,
          'config': remoteMap,
        }),
      );
      final remote = await ContentConfigLoader.load(
        store: store,
        builtIn: builtInWithRemote,
        cacheKey: ContentConfigLoader.childrenRemoteCacheKey,
      );
      expect(remote.childrenCategories.single.id, 'kid_remote');

      // 缓存过期 + 远端不可达 → 回退内置兜底（5 类），不白屏
      await store.setString(
        ContentConfigLoader.childrenRemoteCacheKey,
        jsonEncode({
          'fetched_at': 0,
          'config': remoteMap,
        }),
      );
      final stale = await ContentConfigLoader.load(
        store: store,
        builtIn: ContentConfig.childrenBuiltIn,
        cacheKey: ContentConfigLoader.childrenRemoteCacheKey,
      );
      expect(stale.childrenCategories.length, 5);
    });
  });

  group('儿童内容过滤（100% 白名单口径）', () {
    bool pass(
      String title, {
      int duration = 600,
      String tag = '',
      String upName = '',
      int min = 120,
    }) =>
        DiscoverSource.passesFilter(
          title: title,
          durationSec: duration,
          typeid: 0,
          tag: tag,
          upName: upName,
          category: kidCat(minDurationSec: min),
        );

    test('正向特征词命中（标题/标签/UP 名任一）', () {
      expect(pass('儿童睡前故事：小猪盖房子', duration: 300), isTrue);
      expect(pass('第 12 集', tag: '儿歌,童谣', duration: 90, min: 60), isTrue);
      expect(pass('第 12 集', upName: '宝宝巴士', duration: 300), isTrue);
    });

    test('无特征词不收（白名单宁可漏收）', () {
      expect(pass('凡人修仙传 第 1 集', duration: 3000), isFalse);
      expect(pass('郭德纲相声精选', duration: 3000), isFalse);
    });

    test('成人内容词一票否决（即使含「故事」）', () {
      expect(pass('恐怖故事：深夜病栋', duration: 300), isFalse);
      expect(pass('悬疑故事合集', duration: 300), isFalse);
      expect(pass('都市言情有声剧', duration: 300), isFalse);
      // 浏览器抽样（M6）漏网样本：游戏活动攻略蹭「睡前故事」词
      expect(pass('【重返未来1999】睡前故事活动攻略', duration: 300), isFalse);
    });

    test('时长低于分类门槛不收', () {
      expect(pass('儿歌两首', duration: 30, min: 60), isFalse);
      expect(pass('绘本故事', duration: 100, min: 120), isFalse);
    });

    test('成人分类不受儿童过滤影响（回归）', () {
      final audioCat = CategoryConfig(
        id: 'rec',
        name: '推荐',
        filter: CategoryConfig.filterAudio,
        queries: const [],
      );
      expect(
        DiscoverSource.passesFilter(
          title: '有声小说《十日终焉》',
          durationSec: 3000,
          typeid: 195,
          tag: '',
          upName: '',
          category: audioCat,
        ),
        isTrue,
      );
    });
  });

  group('儿童模式状态与主题优先级（PRD §5.5）', () {
    test('默认关闭；开启/关闭持久化，重启保留', () async {
      final kv = MemoryKeyValueStore();
      final controller = ThemeController(kv);
      await controller.load();
      expect(controller.children, isFalse);
      expect(controller.effectiveThemeMode, ThemeMode.system);

      await controller.setChildren(true);
      expect(controller.children, isTrue);
      expect(kv.getString(ThemeController.childrenKey), '1');

      // 模拟重启：新实例读回
      final reloaded = ThemeController(kv);
      await reloaded.load();
      expect(reloaded.children, isTrue);
      // 主题优先级：儿童 > 用户深色设置
      expect(reloaded.effectiveThemeMode, ThemeMode.light);

      await reloaded.setChildren(false);
      expect(reloaded.effectiveThemeMode, ThemeMode.system);
    });

    test('儿童主题可构建且为浅色（无硬编码穿帮依赖）', () {
      final theme = AppTheme.children;
      expect(theme.brightness, Brightness.light);
      expect(theme.extension<AppTokens>(), isA<AppTokens>());
    });
  });
}
