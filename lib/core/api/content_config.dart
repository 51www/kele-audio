/// - `series`：直接指定合集/系列 id（`season:123` / `series:456`，封闭列表最稳）。
/// 内容源配置（PRD §7.2）：一个「分类」= 一组可配置的查询。
///
/// 加载链路与 [ApiConfigLoader] 同构：**内置 JSON → 远端覆盖**（带 TTL 缓存、
/// 失败静默回退），对应 R1「接口配置可下发」：分类调整 / 关键词 / 黑名单
/// 都可以走静态 JSON 下发，不发版即可生效。
///
/// `source` 三种查询（PRD §7.2 组合策略：**合集/UP 主优先，搜索补充**）：
/// - `search`：WBI 关键词搜索（翻页主链路）；
/// - `up`：指定 UP 主（`up_mids` 直给，或 `up_names` 运行时解析成 mid）→
///   取其合集/系列（`seasons_series_list`，匿名可用）；
/// - `series`：直接指定合集/系列 id（`season:123` / `series:456`，封闭列表最稳）。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import 'key_value_store.dart';

/// 查询来源。
enum QuerySource { search, up, series }

extension QuerySourceX on QuerySource {
  String get wire => switch (this) {
        QuerySource.search => 'search',
        QuerySource.up => 'up',
        QuerySource.series => 'series',
      };

  static QuerySource fromWire(String? v) => switch (v) {
        'up' => QuerySource.up,
        'series' => QuerySource.series,
        _ => QuerySource.search,
      };
}

/// 一条查询配置。
class ContentQuery {
  const ContentQuery({
    required this.source,
    this.keyword = '',
    this.order = '',
    this.scope = 'video',
    this.upMids = const [],
    this.upNames = const [],
    this.seriesIds = const [],
  });

  final QuerySource source;

  /// `source=search`：搜索关键词。
  final String keyword;

  /// `source=search`：排序（`click` 播放量 / `pubdate` 最新 / 空=综合）。
  final String order;

  /// `source=search`：搜索域（`video`）。
  final String scope;

  /// `source=up`：直接指定的 UP 主 mid。
  final List<int> upMids;

  /// `source=up`：按名字解析 mid（bili_user 搜索，结果落 KV 缓存）。
  final List<String> upNames;

  /// `source=series`：合集/系列 id（`season:123` 或 `series:456`）。
  final List<String> seriesIds;

  factory ContentQuery.fromJson(Map<String, dynamic> j) => ContentQuery(
        source: QuerySourceX.fromWire('${j['source'] ?? ''}'),
        keyword: '${j['keyword'] ?? ''}',
        order: '${j['order'] ?? ''}',
        scope: '${j['scope'] ?? 'video'}',
        upMids: [
          for (final e in (j['up_mids'] as List?) ?? const [])
            (e as num).toInt(),
        ],
        upNames: [
          for (final e in (j['up_names'] as List?) ?? const []) '$e',
        ],
        seriesIds: [
          for (final e in (j['series_ids'] as List?) ?? const []) '$e',
        ],
      );

  Map<String, dynamic> toJson() => {
        'source': source.wire,
        if (keyword.isNotEmpty) 'keyword': keyword,
        if (order.isNotEmpty) 'order': order,
        if (scope.isNotEmpty) 'scope': scope,
        if (upMids.isNotEmpty) 'up_mids': upMids,
        if (upNames.isNotEmpty) 'up_names': upNames,
        if (seriesIds.isNotEmpty) 'series_ids': seriesIds,
      };
}

/// 内容过滤模式（基于真实搜索数据调校，见 `.logs/milestone-3.md`）：
/// - [CategoryConfig.filterAudio]：听书信号判定 —— 标题/标签含听书特征词、
///   195 听书分区、或搜索词本身是听书题材词，且满足时长门槛；
/// - [CategoryConfig.filterPlain]：只按时长门槛 + 轻噪音词过滤
///   （讲书/音乐等不能被「解说/解读」这类正向词误杀的分类）。
class CategoryConfig {
  CategoryConfig({
    required this.id,
    required this.name,
    this.mode = 'adult',
    this.filter = filterAudio,
    this.minDurationSec = 300,
    this.queries = const [],
    this.blacklistUpMids = const [],
  });

  static const String filterAudio = 'audio';
  static const String filterPlain = 'plain';

  /// 儿童白名单过滤（M6 / PRD §7.3）：正向特征词命中才收 +
  /// 成人内容词一票否决，见 [DiscoverSource.kidHintWords]。
  static const String filterChildren = 'children';

  /// 搜索结果过滤（M8 搜索页）：只打噪音词，不做白名单口径
  ///（用户主动搜索，尊重意图；时长门槛用分类的 minDurationSec）。
  static const String filterSearch = 'search';

  /// 分类 id（= `category_id`，专辑缓存表用它归类）。
  final String id;
  final String name;

  /// `adult` / `children`（儿童分类 M6 使用，发现页仅展示 adult）。
  final String mode;

  /// 见 [filterAudio] / [filterPlain]。
  final String filter;

  /// 时长门槛（秒）：两种模式都先过这道地板。
  final int minDurationSec;

  final List<ContentQuery> queries;

  /// 黑名单 UP（PRD §7.2，命中一律剔除）。
  final List<int> blacklistUpMids;

  factory CategoryConfig.fromJson(Map<String, dynamic> j) => CategoryConfig(
        id: '${j['category_id'] ?? j['id'] ?? ''}',
        name: '${j['name'] ?? ''}',
        mode: '${j['mode'] ?? 'adult'}',
        filter: '${j['filter'] ?? filterAudio}',
        minDurationSec: (j['min_duration_sec'] as num?)?.toInt() ?? 300,
        queries: [
          for (final e in (j['queries'] as List?) ?? const [])
            if (e is Map)
              ContentQuery.fromJson(Map<String, dynamic>.from(e)),
        ],
        blacklistUpMids: [
          for (final e in (j['blacklist_up_mids'] as List?) ?? const [])
            (e as num).toInt(),
        ],
      );

  Map<String, dynamic> toJson() => {
        'category_id': id,
        'name': name,
        'mode': mode,
        'filter': filter,
        'min_duration_sec': minDurationSec,
        'queries': [for (final q in queries) q.toJson()],
        'blacklist_up_mids': blacklistUpMids,
      };
}

/// 编辑精选专题（M8 / PRD §5.1）：发现页 Banner 与专题卡的配置源。
///
/// 本质是「运营预置的关键词」：点专题卡跳搜索页按 [keyword] 出结果，
/// 运营调整走内容配置下发（R1 通道），不发版。
class FeaturedTopic {
  const FeaturedTopic({
    required this.title,
    this.subtitle = '',
    required this.keyword,
    this.emoji = '🎧',
  });

  final String title;
  final String subtitle;
  final String keyword;

  /// 展示用 emoji（无图片资源时用 emoji + 主题渐变，不写死颜色）。
  final String emoji;

  factory FeaturedTopic.fromJson(Map<String, dynamic> j) => FeaturedTopic(
        title: '${j['title'] ?? ''}',
        subtitle: '${j['subtitle'] ?? ''}',
        keyword: '${j['keyword'] ?? ''}',
        emoji: '${j['emoji'] ?? '🎧'}',
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'subtitle': subtitle,
        'keyword': keyword,
        'emoji': emoji,
      };
}

/// 分类查询配置全集。
class ContentConfig {
  ContentConfig({
    this.version = 1,
    this.remoteConfigUrl = '',
    this.cacheTtlMinutes = 30,
    required this.categories,
    this.featured = const [],
  });

  final int version;

  /// 远端配置覆盖地址（R1 热修复）：空 = 只用内置配置。
  final String remoteConfigUrl;

  /// 分类首页缓存 TTL（分钟，PRD §5.1.2 建议 30 分钟）。
  final int cacheTtlMinutes;

  final List<CategoryConfig> categories;

  /// 编辑精选专题（M8：Banner 轮播 + 专题横滑；空 = 不展示该区块）。
  final List<FeaturedTopic> featured;

  /// 发现页可见分类：成人 5 类（儿童分类 M6 儿童模式下再启用）。
  List<CategoryConfig> get adultCategories =>
      categories.where((c) => c.mode != 'children').toList();

  /// 儿童分类（M6：绘本/儿歌/童话/睡前故事/科普，mode == 'children'）。
  List<CategoryConfig> get childrenCategories =>
      categories.where((c) => c.mode == 'children').toList();

  CategoryConfig? byId(String id) {
    for (final c in categories) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 内置兜底（与 `assets/api/content_config.json` 同内容）：
  /// 配置文件缺失/损坏时不阻塞启动，发现页照常可开。
  factory ContentConfig.builtIn() => ContentConfig(
        categories: [
          CategoryConfig(
            id: 'rec',
            name: '推荐',
            filter: CategoryConfig.filterAudio,
            minDurationSec: 300,
            queries: const [
              ContentQuery(source: QuerySource.up, upMids: [19566500]),
              ContentQuery(
                source: QuerySource.search,
                keyword: '有声小说 全集',
                order: 'click',
              ),
            ],
          ),
          CategoryConfig(
            id: 'xiaoshuo',
            name: '有声书',
            filter: CategoryConfig.filterAudio,
            minDurationSec: 300,
            queries: const [
              ContentQuery(
                source: QuerySource.series,
                seriesIds: ['season:1683170'],
              ),
              ContentQuery(
                source: QuerySource.search,
                keyword: '有声小说',
                order: 'click',
              ),
              ContentQuery(source: QuerySource.search, keyword: '有声书 全集'),
            ],
          ),
          CategoryConfig(
            id: 'xiangsheng',
            name: '相声曲艺',
            filter: CategoryConfig.filterAudio,
            minDurationSec: 300,
            queries: const [
              ContentQuery(
                source: QuerySource.search,
                keyword: '相声',
                order: 'click',
              ),
              ContentQuery(source: QuerySource.search, keyword: '评书'),
            ],
          ),
          CategoryConfig(
            id: 'jiangshu',
            name: '讲书',
            filter: CategoryConfig.filterPlain,
            minDurationSec: 300,
            queries: const [
              ContentQuery(source: QuerySource.search, keyword: '讲书'),
              ContentQuery(source: QuerySource.search, keyword: '好书推荐'),
            ],
          ),
          CategoryConfig(
            id: 'music',
            name: '音乐',
            filter: CategoryConfig.filterPlain,
            minDurationSec: 180,
            queries: const [
              ContentQuery(
                source: QuerySource.search,
                keyword: '纯音乐',
                order: 'click',
              ),
              ContentQuery(source: QuerySource.search, keyword: '音乐合集'),
            ],
          ),
        ],
        // 编辑精选（M8 / PRD §5.1）：Banner + 专题横滑，点卡跳搜索页。
        // 关键词由人工运营挑选，可经内容配置远端下发调整。
        featured: const [
          FeaturedTopic(
            title: '高分有声书精选',
            subtitle: '编辑每周人工核对',
            keyword: '有声书 高分 全集',
            emoji: '📚',
          ),
          FeaturedTopic(
            title: '经典评书专场',
            subtitle: '单田芳 / 田连元',
            keyword: '评书 全集',
            emoji: '📻',
          ),
          FeaturedTopic(
            title: '睡前放松纯音乐',
            subtitle: '助眠 · 解压',
            keyword: '纯音乐 助眠',
            emoji: '🌙',
          ),
        ],
      );

  /// 儿童白名单内置兜底（与 `assets/api/children_config.json` 同内容）：
  /// 儿童配置文件缺失/损坏时兜底，保证儿童模式不白屏。
  factory ContentConfig.childrenBuiltIn() => ContentConfig(
        categories: [
          CategoryConfig(
            id: 'kid_huiBen',
            name: '绘本',
            mode: 'children',
            filter: CategoryConfig.filterChildren,
            minDurationSec: 120,
            queries: const [
              ContentQuery(source: QuerySource.search, keyword: '绘本故事'),
              ContentQuery(source: QuerySource.search, keyword: '有声绘本'),
            ],
          ),
          CategoryConfig(
            id: 'kid_erGe',
            name: '儿歌',
            mode: 'children',
            filter: CategoryConfig.filterChildren,
            minDurationSec: 60,
            queries: const [
              ContentQuery(source: QuerySource.search, keyword: '儿歌'),
              ContentQuery(source: QuerySource.search, keyword: '童谣'),
            ],
          ),
          CategoryConfig(
            id: 'kid_tongHua',
            name: '童话',
            mode: 'children',
            filter: CategoryConfig.filterChildren,
            minDurationSec: 120,
            queries: const [
              ContentQuery(source: QuerySource.search, keyword: '童话故事'),
              ContentQuery(source: QuerySource.search, keyword: '格林童话'),
            ],
          ),
          CategoryConfig(
            id: 'kid_shuiQian',
            name: '睡前故事',
            mode: 'children',
            filter: CategoryConfig.filterChildren,
            minDurationSec: 120,
            queries: const [
              ContentQuery(source: QuerySource.search, keyword: '睡前故事'),
              ContentQuery(source: QuerySource.search, keyword: '儿童睡前故事'),
            ],
          ),
          CategoryConfig(
            id: 'kid_kePu',
            name: '科普',
            mode: 'children',
            filter: CategoryConfig.filterChildren,
            minDurationSec: 120,
            queries: const [
              ContentQuery(source: QuerySource.search, keyword: '儿童科普'),
              ContentQuery(source: QuerySource.search, keyword: '十万个为什么'),
            ],
          ),
        ],
      );

  factory ContentConfig.fromJson(Map<String, dynamic> j) => ContentConfig(
        version: (j['version'] as num?)?.toInt() ?? 1,
        remoteConfigUrl: '${j['remote_config_url'] ?? ''}',
        cacheTtlMinutes: (j['cache_ttl_minutes'] as num?)?.toInt() ?? 30,
        categories: [
          for (final e in (j['categories'] as List?) ?? const [])
            if (e is Map)
              CategoryConfig.fromJson(Map<String, dynamic>.from(e)),
        ],
        featured: [
          for (final e in (j['featured'] as List?) ?? const [])
            if (e is Map) FeaturedTopic.fromJson(Map<String, dynamic>.from(e)),
        ],
      );

  Map<String, dynamic> toJson() => {
        'version': version,
        'remote_config_url': remoteConfigUrl,
        'cache_ttl_minutes': cacheTtlMinutes,
        'categories': [for (final c in categories) c.toJson()],
        'featured': [for (final f in featured) f.toJson()],
      };
}

/// 配置加载：内置 JSON → 远端覆盖（带 TTL 缓存，失败静默回退）。
class ContentConfigLoader {
  ContentConfigLoader._();

  static const String remoteCacheKey = 'content_config_remote_json';

  /// 儿童白名单远端覆盖缓存 key（M6，与成人配置分开存）。
  static const String childrenRemoteCacheKey = 'children_config_remote_json';

  /// [bundledJson]：读取随包配置（App 传 `rootBundle.loadString`，测试传 null）。
  /// [builtIn]：内置兜底（成人主配置 / 儿童白名单各一份）。
  /// [cacheKey]：远端覆盖缓存 key（成人 / 儿童配置分开存，互不污染）。
  static Future<ContentConfig> load({
    required KeyValueStore store,
    Future<String?> Function()? bundledJson,
    ContentConfig Function()? builtIn,
    String cacheKey = remoteCacheKey,
    Duration remoteTtl = const Duration(hours: 6),
    Duration timeout = const Duration(seconds: 6),
  }) async {
    var config = builtIn?.call() ?? ContentConfig.builtIn();

    if (bundledJson != null) {
      try {
        final raw = await bundledJson();
        if (raw != null && raw.trim().isNotEmpty) {
          final parsed =
              ContentConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
          if (parsed.categories.isNotEmpty) config = parsed;
        }
      } catch (_) {
        // 配置损坏 → 回退内置分类，绝不阻塞启动
      }
    }

    // 远端覆盖：命中缓存直接用；否则现拉一次（静态 JSON，不受 B 站风控约束）
    final remote = config.remoteConfigUrl.trim();
    if (remote.isEmpty) return config;

    try {
      final cached = store.getString(cacheKey);
      if (cached != null) {
        final map = jsonDecode(cached) as Map<String, dynamic>;
        final fetchedAt = (map['fetched_at'] as num?)?.toInt() ?? 0;
        final age = DateTime.now().millisecondsSinceEpoch - fetchedAt;
        if (age < remoteTtl.inMilliseconds) {
          final parsed = ContentConfig.fromJson(
            map['config'] as Map<String, dynamic>,
          );
          if (parsed.categories.isNotEmpty) return parsed;
        }
      }
      final res = await Dio(BaseOptions(
        connectTimeout: timeout,
        receiveTimeout: timeout,
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      )).get<String>(remote);
      final body = res.data;
      if (res.statusCode == 200 && body != null && body.trim().isNotEmpty) {
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        final parsed = ContentConfig.fromJson(decoded);
        if (parsed.categories.isNotEmpty) {
          await store.setString(cacheKey, jsonEncode({
            'fetched_at': DateTime.now().millisecondsSinceEpoch,
            'config': decoded,
          }));
          return parsed;
        }
      }
    } catch (_) {
      // 拉取失败沿用内置配置（热修复失败不能影响可用性）
    }
    return config;
  }
}
