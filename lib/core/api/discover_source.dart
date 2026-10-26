import '../domain/album.dart';
import 'api_config.dart';
import 'bili_client.dart';
import 'content_config.dart';
import 'key_value_store.dart';

/// 一页聚合结果。
class DiscoverPageData {
  const DiscoverPageData({
    required this.items,
    required this.hasMore,
    required this.page,
  });

  final List<Album> items;
  final bool hasMore;
  final int page;
}

/// 发现页聚合源（M3 任务 2）：按 [CategoryConfig] 把「合集/UP 主 + 搜索」
/// 聚合成一页专辑卡片。
///
/// 组合策略（PRD §7.2）：**合集/UP 主优先，搜索补充** ——
/// page 1 先取 `up` / `series` 专用源（封闭、质量高），再按序补搜索；
/// page 2+ 只翻搜索（合集/UP 源只出第一页，避免无谓请求）。
///
/// 约束：
/// - 一切请求走 [BiliClient]（450ms 节流 / WBI / 阶梯退避），**串行发起**，
///   并发会打乱全局节流（R2 勿改）；
/// - 风控兜底：`v_voucher` / -412 命中后按 1500ms×尝试 蓄力重试（≤3 次），
///   与 abts `_searchRaw` 同口径；
/// - 过滤与去重：[passesFilter]（时长 + 噪音词 + 听书信号）→ 按专辑 id 去重
///   → 黑名单 UP 剔除。
class DiscoverSource {
  DiscoverSource({
    required this.client,
    required this.config,
    required this.kv,
    this.log,
  });

  final BiliClient client;
  final ApiConfig config;
  final KeyValueStore kv;
  final void Function(String message)? log;

  /// 搜索页大小（B 站上限 50，20 为常规口径）。
  static const int pageSize = 20;

  /// 风控重试上限与退避基数（v_voucher / -412）。
  static const int _voucherMaxRetry = 3;

  void _log(String msg) => log?.call(msg);

  // -------------------------------------------------------------- 聚合入口

  /// 取某分类的第 [page] 页。
  ///
  /// page 1：`up` / `series` 源（失败单个跳过，不拖垮整页）+ 全部 `search` 查询；
  /// page 2+：仅 `search`。任一搜索查询抛错则整页抛错（UI 展示错误态 + 重试）。
  Future<DiscoverPageData> fetchPage(CategoryConfig category, int page) async {
    final items = <Album>[];
    var hasMore = false;

    if (page <= 1) {
      for (final q in category.queries) {
        if (q.source == QuerySource.search) continue;
        try {
          items.addAll(await _albumsFromSource(q, category));
        } catch (e) {
          // 专用源失败降级为「只有搜索」，不让单点故障白屏
          _log('[discover] source ${q.source.wire} failed: $e');
        }
      }
    }

    for (final q in category.queries) {
      if (q.source != QuerySource.search) continue;
      final res = await _searchPage(q, page, category);
      hasMore = hasMore || res.hasMore;
      items.addAll(res.items);
    }

    final seen = <String>{};
    final out = <Album>[];
    for (final a in items) {
      if (a.id.isEmpty || !seen.add(a.id)) continue;
      if (category.blacklistUpMids.contains(a.upMid)) continue;
      out.add(a);
    }
    return DiscoverPageData(items: out, hasMore: hasMore, page: page);
  }

  /// 关键词搜索（M8 搜索页 / PRD §5.1）。
  ///
  /// `filterSearch` 口径：仅噪音词 + 60s 时长地板，不做白名单/听书信号
  /// 判定（用户主动搜索，尊重意图）。复用 `_searchRaw` 的风控兜底。
  Future<DiscoverPageData> searchAlbums({
    required String keyword,
    int page = 1,
  }) async {
    final category = CategoryConfig(
      id: 'search',
      name: '搜索',
      filter: CategoryConfig.filterSearch,
      minDurationSec: 60,
      queries: const [],
    );
    final query = ContentQuery(source: QuerySource.search, keyword: keyword);
    final res = await _searchPage(query, page, category);
    final seen = <String>{};
    final items = [
      for (final a in res.items)
        if (a.id.isNotEmpty && seen.add(a.id)) a,
    ];
    return DiscoverPageData(items: items, hasMore: res.hasMore, page: page);
  }

  // ------------------------------------------------------------ 搜索（主干）

  Future<DiscoverPageData> _searchPage(
    ContentQuery query,
    int page,
    CategoryConfig category,
  ) async {
    final raw = await _searchRaw(query, page);
    final data = raw['data'] is Map
        ? raw['data'] as Map<String, dynamic>
        : <String, dynamic>{};
    final list = data['result'] is List ? data['result'] as List : const [];
    final numResults = _toInt(data['numResults']);

    final items = <Album>[];
    for (final it in list) {
      if (it is! Map) continue;
      final item = Map<String, dynamic>.from(it);
      final album = albumFromSearch(item, categoryId: category.id);
      if (album == null) continue;
      if (!passesFilter(
        title: album.title,
        durationSec: album.totalDurationSec,
        typeid: _toInt(item['typeid']),
        tag: '${item['tag'] ?? ''}',
        upName: album.upName,
        category: category,
      )) {
        continue;
      }
      items.add(album);
    }
    final hasMore = list.isNotEmpty && page * pageSize < numResults;
    return DiscoverPageData(items: items, hasMore: hasMore, page: page);
  }

  /// 任意形态 → int（B 站数值字段有时是字符串：`"195"` / `"20135253"`，
  /// 有时是 number，统一容错）。
  static int _toInt(Object? v) {
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}') ?? 0;
  }

  /// 发一次搜索（带 v_voucher / -412 蓄力重试）。返回解码后的 body。
  Future<Map<String, dynamic>> _searchRaw(ContentQuery query, int page) async {
    Object? lastError;
    for (var attempt = 0; attempt < _voucherMaxRetry; attempt++) {
      try {
        final res = await client.get(
          config.url(BiliPaths.searchType),
          query: {
            'search_type': query.scope.isEmpty ? 'video' : query.scope,
            'keyword': query.keyword,
            'page': page,
            'page_size': pageSize,
            if (query.order.isNotEmpty) 'order': query.order,
          },
          useWbi: true,
          headers: {'Referer': config.searchHome},
        );
        final data = res.data;
        if (data is Map) return Map<String, dynamic>.from(data);
        return const <String, dynamic>{};
      } on BiliApiException catch (e) {
        lastError = e;
        // get() 内部已做过 [1200,2600,5000] 阶梯退避；仍失败说明是
        // v_voucher 类持续风控，这里再按 1500ms×尝试 蓄力补刀（≤3 次）
        if (e.code == -412 && attempt + 1 < _voucherMaxRetry) {
          final wait = 1500 * (attempt + 1);
          _log('[discover] search risk hit, extra backoff ${wait}ms');
          await Future<void>.delayed(Duration(milliseconds: wait));
          continue;
        }
        rethrow;
      }
    }
    throw lastError ?? BiliApiException(-1, '搜索失败');
  }

  // ---------------------------------------------------- 专用源（up / series)

  Future<List<Album>> _albumsFromSource(
    ContentQuery query,
    CategoryConfig category,
  ) async {
    switch (query.source) {
      case QuerySource.up:
        final mids = <int>{
          ...query.upMids,
          for (final n in query.upNames)
            if (n.trim().isNotEmpty) await _resolveUpMid(n.trim()),
        }..remove(0);
        final out = <Album>[];
        for (final mid in mids) {
          out.addAll(await _upCollections(mid, category));
        }
        return out;
      case QuerySource.series:
        final out = <Album>[];
        for (final ref in query.seriesIds) {
          final album = await _collectionPreview(ref, category);
          if (album != null) out.add(album);
        }
        return out;
      case QuerySource.search:
        return const [];
    }
  }

  /// UP 主 → 其全部合集/系列（`seasons_series_list`，page 1 的 20 个够用）。
  Future<List<Album>> _upCollections(int mid, CategoryConfig category) async {
    final res = await client.get(
      config.url(BiliPaths.upCollections),
      query: {'mid': mid, 'page_num': 1, 'page_size': 20},
      useWbi: true,
      headers: {'Referer': '${config.homeBase}/space/$mid'},
    );
    final data = res.data is Map ? res.data['data'] : null;
    final lists = data is Map ? data['items_lists'] : null;
    if (lists is! Map) return const [];
    final seasons = lists['seasons_list'] is List
        ? lists['seasons_list'] as List
        : const [];
    final series = lists['series_list'] is List
        ? lists['series_list'] as List
        : const [];

    final albums = <Album>[
      for (final raw in seasons)
        if (raw is Map)
          albumFromCollectionMeta(
            // seasons_series_list 的条目形如 {archives, meta, recent_aids}，
            // meta 嵌套在内（实测 2026-10）
            Map<String, dynamic>.from(
              raw['meta'] is Map
                  ? Map<String, dynamic>.from(raw['meta'] as Map)
                  : raw,
            ),
            isSeason: true,
            categoryId: category.id,
          ),
      for (final raw in series)
        if (raw is Map)
          albumFromCollectionMeta(
            Map<String, dynamic>.from(
              raw['meta'] is Map
                  ? Map<String, dynamic>.from(raw['meta'] as Map)
                  : raw,
            ),
            isSeason: false,
            categoryId: category.id,
            seriesId: _toInt(raw['series_id'] ?? (raw['meta'] is Map
                ? (raw['meta'] as Map)['series_id']
                : null)),
          ),
    ];
    if (albums.isEmpty) return albums;
    final name = await upNameOf(mid);
    return [for (final a in albums) a.copyWith(upName: name)];
  }

  /// 显式合集/系列引用 → 预览专辑卡片。
  ///
  /// [ref] 形如 `season:123`（无需 mid）或 `series:456@<mid>`
  /// （`seasons_archives_list` 的 series 查询**必带 mid**，实测无 mid 报 -352）。
  Future<Album?> _collectionPreview(
    String ref,
    CategoryConfig category,
  ) async {
    final sep = ref.indexOf(':');
    final kind = sep > 0 ? ref.substring(0, sep) : 'season';
    final rest = sep > 0 ? ref.substring(sep + 1) : ref;
    final parts = rest.split('@');
    final id = int.tryParse(parts.first.trim()) ?? 0;
    final mid = parts.length > 1 ? int.tryParse(parts[1].trim()) ?? 0 : 0;
    if (id == 0) return null;

    final query = <String, dynamic>{
      if (kind == 'series')
        ...{'series_id': id, 'mid': mid}
      else
        ...{'season_id': id},
      'page_num': 1,
      'page_size': 1,
    };
    final res = await client.get(
      config.url(BiliPaths.upCollectionArchives),
      query: query,
      useWbi: true,
    );
    final data = res.data is Map ? res.data['data'] : null;
    if (data is! Map) return null;
    final meta = data['meta'];
    if (meta is! Map) return null;
    final album = albumFromCollectionMeta(
      Map<String, dynamic>.from(meta),
      isSeason: kind != 'series',
      categoryId: category.id,
      seriesId: kind != 'series' ? 0 : id,
    );
    final upMid = album.upMid > 0 ? album.upMid : mid;
    return album.copyWith(upMid: upMid, upName: await upNameOf(upMid));
  }

  // -------------------------------------------------------- UP 名字解析缓存

  /// UP 主名字 → mid（`search_type=bili_user`，精确名优先、否则粉丝数最多；
  /// 结果落 KV，一次解析终身复用）。拿不到时返回 0（跳过该 UP，不阻塞）。
  Future<int> _resolveUpMid(String name) async {
    final key = 'discover_up_mid:$name';
    final cached = int.tryParse(kv.getString(key) ?? '') ?? 0;
    if (cached > 0) return cached;
    try {
      final res = await client.get(
        config.url(BiliPaths.searchType),
        query: {'search_type': 'bili_user', 'keyword': name, 'page': 1},
        useWbi: true,
        headers: {'Referer': config.searchHome},
      );
      final data = res.data is Map ? res.data['data'] : null;
      final list = data is Map && data['result'] is List
          ? data['result'] as List
          : const [];
      var best = 0;
      var bestFans = -1;
      for (final raw in list) {
        if (raw is! Map) continue;
        final mid = int.tryParse('${raw['mid'] ?? ''}') ?? 0;
        if (mid == 0) continue;
        if ('${raw['uname'] ?? ''}' == name) {
          best = mid;
          break;
        }
        final fans = int.tryParse('${raw['fans'] ?? ''}') ?? 0;
        if (fans > bestFans) {
          bestFans = fans;
          best = mid;
        }
      }
      if (best > 0) await kv.setString(key, '$best');
      return best;
    } catch (e) {
      _log('[discover] resolve up "$name" failed: $e');
      return 0;
    }
  }

  /// mid → UP 名（`x/web-interface/card`，免 WBI 免风控；结果落 KV）。
  ///
  /// 合集/系列接口的 meta 里**没有** up_name / upmid（实测见
  /// `tool/spike/m3_shape_result.json`），详情页与卡片都靠这里补。
  Future<String> upNameOf(int mid) async {
    if (mid <= 0) return '';
    final key = 'discover_up_name:$mid';
    final cached = kv.getString(key);
    if (cached != null && cached.isNotEmpty) return cached;
    try {
      final res = await client.get(
        config.url(BiliPaths.userCard),
        query: {'mid': mid, 'photo': 'false'},
      );
      final body = res.data is Map ? res.data['data'] : null;
      final card = body is Map ? body['card'] : null;
      final name = card is Map ? _stripHtml('${card['name'] ?? ''}') : '';
      if (name.isNotEmpty) await kv.setString(key, name);
      return name;
    } catch (e) {
      _log('[discover] up name of $mid failed: $e');
      return '';
    }
  }

  // -------------------------------------------------------------- 纯函数区

  /// 时长解析：`mm:ss` / `h:mm:ss`，按 60 进制折叠（B 站有声内容动辄
  /// `25724:11`，分钟位不限宽）。
  static int parseDurationSeconds(String raw) {
    final parts = raw.trim().split(':');
    if (parts.isEmpty) return 0;
    var acc = 0;
    for (final p in parts) {
      final v = int.tryParse(p.trim());
      if (v == null || v < 0) return 0;
      acc = acc * 60 + v;
    }
    return acc;
  }

  /// 内容过滤（PRD §7.2，基于真实搜索数据调校）：
  ///
  /// - [CategoryConfig.filterPlain]（讲书/音乐）：时长 ≥ 门槛 + 轻噪音词；
  /// - [CategoryConfig.filterAudio]（推荐/有声书/相声曲艺）：噪音词一票否决，
  ///   然后听书信号判定 —— 标题含听书特征词（≥300s）、195 听书分区
  ///   （≥600s）、UP 名/标签含听书特征词（≥1800s），满足其一即收。
  static bool passesFilter({
    required String title,
    required int durationSec,
    required int typeid,
    required String tag,
    required String upName,
    required CategoryConfig category,
  }) {
    if (durationSec <= 0) return false;
    final noise = _containsAny(title, noiseWords);
    if (category.filter == CategoryConfig.filterSearch) {
      // 搜索结果（M8）：用户主动意图优先，仅噪音词 + 时长地板
      return !noise && durationSec >= category.minDurationSec;
    }
    if (category.filter == CategoryConfig.filterChildren) {
      return passesChildrenFilter(
        title: title,
        durationSec: durationSec,
        tag: tag,
        upName: upName,
        minDurationSec: category.minDurationSec,
      );
    }
    if (category.filter == CategoryConfig.filterPlain) {
      if (durationSec < category.minDurationSec) return false;
      return !noise;
    }
    // audio 模式
    final floor = category.minDurationSec < 300 ? 300 : category.minDurationSec;
    if (durationSec < floor) return false;
    if (noise) return false;
    if (_containsAny(title, audioHintWords)) return true;
    if (typeid == 195 && durationSec >= 600) return true;
    if (durationSec >= 1800 &&
        (_containsAny(upName, audioHintWords) ||
            _containsAny(tag, audioHintWords))) {
      return true;
    }
    return false;
  }

  /// 儿童白名单过滤（PRD §5.5 / §7.3，R4 无官方元数据 → 关键词白名单）：
  ///
  /// 1. 成人内容词一票否决（标题，白名单宁可错杀）；
  /// 2. 正向特征词命中才收：标题/标签/UP 名至少一处含儿童内容词，
  ///    保证「内容 100% 来自白名单口径」（抽样核对可解释）；
  /// 3. 时长 ≥ 分类门槛（儿歌 60s，其余 120s）。
  static bool passesChildrenFilter({
    required String title,
    required int durationSec,
    required String tag,
    required String upName,
    required int minDurationSec,
  }) {
    if (durationSec < minDurationSec) return false;
    if (_containsAny(title, kidNoiseWords)) return false;
    return _containsAny(title, kidHintWords) ||
        _containsAny(tag, kidHintWords) ||
        _containsAny(upName, kidHintWords);
  }

  /// 标题 → 专辑（搜索结果）。`bvid` 为空或标题为空时返回 null。
  static Album? albumFromSearch(
    Map<String, dynamic> item, {
    String categoryId = '',
  }) {
    final bvid = '${item['bvid'] ?? ''}';
    final title = _stripHtml('${item['title'] ?? ''}');
    if (bvid.isEmpty || title.isEmpty) return null;
    return Album(
      id: bvid,
      sourceType: SourceType.multiPart,
      title: title,
      coverUrl: normalizePic('${item['pic'] ?? ''}'),
      upName: _stripHtml('${item['author'] ?? ''}'),
      chapterCount: int.tryParse('${item['videos'] ?? ''}') ?? 0,
      categoryId: categoryId,
      bvid: bvid,
      upMid: int.tryParse('${item['mid'] ?? ''}') ?? 0,
      intro: _stripHtml('${item['description'] ?? item['desc'] ?? ''}'),
      totalDurationSec: parseDurationSeconds('${item['duration'] ?? ''}'),
      playCount: int.tryParse('${item['play'] ?? ''}') ?? 0,
      createdAt: (int.tryParse('${item['pubdate'] ?? ''}') ?? 0) * 1000,
    );
  }

  /// 合集/系列 meta → 专辑卡片。meta 没有 up_name（实测），upName 由调用方
  /// 用 [upNameOf] 补。`isSeason=false` 时 [seriesId] 必填（meta 里没有 id）。
  static Album albumFromCollectionMeta(
    Map<String, dynamic> meta, {
    required bool isSeason,
    String categoryId = '',
    int seriesId = 0,
  }) {
    final idNum = isSeason ? _toInt(meta['season_id']) : seriesId;
    final title = _stripHtml(
      '${meta['title'] ?? meta['name'] ?? ''}',
    );
    return Album(
      id: isSeason ? 'season:$idNum' : 'series:$idNum',
      sourceType: SourceType.series,
      title: title.isEmpty ? (isSeason ? '合集 $idNum' : '系列 $idNum') : title,
      coverUrl: '${meta['cover'] ?? ''}',
      upName: _stripHtml('${meta['up_name'] ?? ''}'),
      chapterCount: _toInt(meta['total']),
      categoryId: categoryId,
      upMid: _toInt(meta['upmid']) > 0
          ? _toInt(meta['upmid'])
          : _toInt(meta['mid']),
      intro: _stripHtml('${meta['description'] ?? ''}'),
      createdAt: _toInt(meta['ptime']) * 1000,
    );
  }

  /// 封面地址归一：`//i1.hdslb.com/...` → `https://...`。
  static String normalizePic(String pic) {
    final p = pic.trim();
    if (p.startsWith('//')) return 'https:$p';
    return p;
  }

  static String _stripHtml(String s) => s
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&nbsp;', ' ')
      .trim();

  static bool _containsAny(String text, List<String> words) {
    final lower = text.toLowerCase();
    for (final w in words) {
      if (lower.contains(w.toLowerCase())) return true;
    }
    return false;
  }

  /// 噪音词（一票否决）：这些内容不适合「听」的场景。
  static const List<String> noiseWords = [
    '鬼畜',
    '混剪',
    '沙雕',
    'reaction',
    '游戏实况',
    '配音秀',
    '漫推',
    '漫画',
    '动画',
    '预告',
    '速看',
  ];

  /// 听书信号词（audio 模式正向判定）。
  static const List<String> audioHintWords = [
    '有声',
    '听书',
    '评书',
    '相声',
    '广播剧',
    '演播',
    '有声剧',
    '有声小说',
    '讲书',
    '单口',
    '大鼓',
    '快板',
    '琴书',
    '鼓书',
    '戏曲',
  ];

  /// 儿童内容特征词（children 白名单正向判定，M6）。
  static const List<String> kidHintWords = [
    '儿童',
    '孩子',
    '宝宝',
    '幼儿',
    '少儿',
    '亲子',
    '启蒙',
    '绘本',
    '儿歌',
    '童谣',
    '童话',
    '睡前故事',
    '故事',
    '睡前',
    '十万个为什么',
    '国学',
    '古诗',
    '成语故事',
    '寓言',
    '安徒生',
    '格林',
    '科普',
    '恐龙',
    '西游记（少儿）',
  ];

  /// 儿童模式一票否决词（白名单口径：宁可错杀，发现即加入）。
  static const List<String> kidNoiseWords = [
    '鬼畜',
    '混剪',
    '沙雕',
    'reaction',
    '游戏实况',
    '配音秀',
    '漫推',
    '恐怖',
    '惊悚',
    '悬疑',
    '灵异',
    '细思极恐',
    '都市',
    '言情',
    '恋',
    '赘婿',
    '爽文',
    '职场',
    '宫斗',
    '盗墓',
    '末世',
    '打赏',
    '直播',
    '小说推文',
    '攻略',
    '抽卡',
    '活动奖励',
  ];
}
