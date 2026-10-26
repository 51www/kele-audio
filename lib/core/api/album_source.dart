import '../domain/album.dart';
import 'api_config.dart';
import 'bili_client.dart';

/// 专辑 + 完整章节列表（一次「章节来源」查询的结果）。
class AlbumBundle {
  const AlbumBundle({required this.album, required this.chapters});

  final Album album;
  final List<Chapter> chapters;
}

/// 章节来源抽象（M2 任务 1）：把 PRD §7.5 的两种 `source_type` 收敛到一个入口。
///
/// - **多 P**（`SourceType.multiPart`）：一个 bvid = 一张专辑，
///   `view` / `pagelist` 给出全部分 P —— 每个分 P 一个章节，cid 现成；
/// - **合集/系列**（`SourceType.series`）：season/series 下每条视频一个章节，
///   列表来自 `seasons_archives_list`（匿名可用），**cid 懒解析**：
///   真正播放前由 [resolveCid] 用 `view` 补齐（archive 列表里没有 cid）。
///
/// 取数一律走 `core/api/BiliClient`（450ms 节流 / 阶梯退避 / WBI），
/// 本类不自己发请求。
class AlbumSource {
  AlbumSource({required this.client, required this.config, this.log});

  final BiliClient client;
  final ApiConfig config;
  final void Function(String message)? log;

  /// M2 冒烟样本兜底 bvid（多 P，M0 冒烟已验证可取址）
  static const String fallbackSampleBvid = 'BV1xCJv6bEHx';

  static String _stripHtml(String s) => s
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .trim();

  /// 统一入口：按 source_type 分发。
  Future<AlbumBundle> load({
    required String id,
    required SourceType sourceType,
    String categoryId = '',
    int upMid = 0,
  }) =>
      sourceType == SourceType.series
          ? loadSeries(id, categoryId: categoryId, upMid: upMid)
          : loadMultiPart(id, categoryId: categoryId);

  // ---------------------------------------------------------------- 多 P

  /// 多 P 视频 → 专辑 + 章节。优先 `view.pages`，为空时回退 `pagelist`。
  Future<AlbumBundle> loadMultiPart(
    String bvid, {
    String categoryId = '',
    String? referer,
  }) async {
    final ref = referer ?? '${config.homeBase}/video/$bvid';
    final res = await client.get(
      config.url(BiliPaths.view),
      query: {'bvid': bvid},
      headers: {'Referer': ref},
    );
    final data = res.data is Map ? res.data['data'] : null;
    if (data is! Map) throw BiliApiException(-1, '视频信息为空：$bvid');

    final pages = <Map<String, dynamic>>[
      if (data['pages'] is List)
        for (final p in (data['pages'] as List))
          if (p is Map) Map<String, dynamic>.from(p),
    ];
    final list = pages.isNotEmpty ? pages : await _pageListFallback(bvid, ref);

    final owner = data['owner'];
    final stat = data['stat'];
    final album = Album(
      id: bvid,
      sourceType: SourceType.multiPart,
      title: _stripHtml('${data['title'] ?? ''}'),
      coverUrl: '${data['pic'] ?? ''}',
      upName: owner is Map ? _stripHtml('${owner['name'] ?? ''}') : '',
      chapterCount: list.length,
      categoryId: categoryId,
      bvid: bvid,
      upMid: owner is Map ? (owner['mid'] as num?)?.toInt() ?? 0 : 0,
      intro: _stripHtml('${data['desc'] ?? ''}'),
      playCount: stat is Map ? (stat['view'] as num?)?.toInt() ?? 0 : 0,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    return AlbumBundle(
      album: album,
      chapters: _chaptersFromPages(bvid, list),
    );
  }

  Future<List<Map<String, dynamic>>> _pageListFallback(
    String bvid,
    String referer,
  ) async {
    final res = await client.get(
      config.url(BiliPaths.pageList),
      query: {'bvid': bvid},
      headers: {'Referer': referer},
    );
    final list = res.data is Map ? res.data['data'] : null;
    if (list is! List) return const [];
    return [
      for (final p in list)
        if (p is Map) Map<String, dynamic>.from(p),
    ];
  }

  List<Chapter> _chaptersFromPages(
    String bvid,
    List<Map<String, dynamic>> pages,
  ) {
    final chapters = <Chapter>[];
    for (var i = 0; i < pages.length; i++) {
      final p = pages[i];
      final cid = (p['cid'] as num?)?.toInt() ?? 0;
      if (cid == 0) continue;
      final part = _stripHtml('${p['part'] ?? ''}');
      chapters.add(Chapter(
        id: Chapter.keyOf(bvid, cid),
        albumId: bvid,
        index: chapters.length,
        title: part.isEmpty ? '第 ${i + 1} 章' : part,
        durationSec: (p['duration'] as num?)?.toInt() ?? 0,
        bvid: bvid,
        cid: cid,
      ));
    }
    return chapters;
  }

  // -------------------------------------------------------------- 合集/系列

  /// 合集/系列 → 专辑 + 章节（章节的 cid 懒解析，见 [resolveCid]）。
  ///
  /// [id] 形如 `season:123` 或 `series:456`，也接受纯数字（按 season 处理）。
  ///
  /// [upMid]：`series:` 查询**必带 mid**（实测无 mid 报 -352），
  /// 详情页从本地专辑缓存（发现页卡片入库）取到后传入。
  Future<AlbumBundle> loadSeries(
    String id, {
    String categoryId = '',
    int pageSize = 30,
    int upMid = 0,
  }) async {
    final isSeries = id.startsWith('series:');
    final rawId = id.contains(':') ? id.substring(id.indexOf(':') + 1) : id;
    final seasonId = int.tryParse(rawId) ?? 0;
    if (seasonId == 0) {
      throw BiliApiException(-1, '合集 id 非法：$id');
    }

    final query = <String, dynamic>{};
    if (isSeries) {
      query['series_id'] = seasonId;
      if (upMid > 0) query['mid'] = upMid;
    } else {
      query['season_id'] = seasonId;
    }
    query['page_num'] = 1;
    query['page_size'] = pageSize;

    final res = await client.get(
      config.url(BiliPaths.upCollectionArchives),
      query: query,
    );
    final data = res.data is Map ? res.data['data'] : null;
    if (data is! Map) throw BiliApiException(-1, '合集信息为空：$id');

    final meta = data['meta'];
    final archives = data['archives'];
    final list = archives is List ? archives : const [];

    final albumId = id.contains(':') ? id : 'season:$seasonId';
    // meta 实测键：[category, cover, description, mid, name, ptime,
    // season_id, total, title] —— 没有 up_name / upmid（见
    // tool/spike/m3_shape_result.json），upName 由详情页经 card 接口补。
    final album = Album(
      id: albumId,
      sourceType: SourceType.series,
      title: meta is Map
          ? _stripHtml('${meta['title'] ?? meta['name'] ?? ''}')
          : '合集 $seasonId',
      coverUrl: meta is Map ? '${meta['cover'] ?? ''}' : '',
      upName: meta is Map ? _stripHtml('${meta['up_name'] ?? ''}') : '',
      chapterCount:
          meta is Map ? (meta['total'] as num?)?.toInt() ?? list.length : list.length,
      categoryId: categoryId,
      upMid: meta is Map
          ? (meta['upmid'] as num?)?.toInt() ??
              (meta['mid'] as num?)?.toInt() ??
              0
          : 0,
      intro: meta is Map ? _stripHtml('${meta['description'] ?? ''}') : '',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    final chapters = <Chapter>[];
    for (final raw in list) {
      if (raw is! Map) continue;
      final bvid = '${raw['bvid'] ?? ''}';
      if (bvid.isEmpty) continue;
      chapters.add(Chapter(
        id: Chapter.keyOf(albumId, chapters.length + 1),
        albumId: albumId,
        index: chapters.length,
        title: _stripHtml('${raw['title'] ?? ''}'),
        durationSec: ((raw['duration'] as num?)?.toInt() ?? 0),
        bvid: bvid,
        cid: 0, // 系列条目 cid 需要播放前补齐
      ));
    }
    return AlbumBundle(album: album, chapters: chapters);
  }

  /// 合集章节的 cid 懒解析：`view` 未带 pages 时退回 `pagelist`。
  Future<int> resolveCid(Chapter chapter) async {
    if (chapter.cid != 0) return chapter.cid;
    if (chapter.bvid.isEmpty) return 0;
    final referer = '${config.homeBase}/video/${chapter.bvid}';
    try {
      final res = await client.get(
        config.url(BiliPaths.view),
        query: {'bvid': chapter.bvid},
        headers: {'Referer': referer},
      );
      final data = res.data is Map ? res.data['data'] : null;
      if (data is Map && data['cid'] is num) {
        return (data['cid'] as num).toInt();
      }
    } catch (e) {
      _log('[album] view 补 cid 失败 $e');
    }
    final pages = await _pageListFallback(chapter.bvid, referer);
    return pages.isEmpty ? 0 : (pages.first['cid'] as num?)?.toInt() ?? 0;
  }

  // ------------------------------------------------------------ M2 播放样本

  /// M2 试听样本：搜一个**多 P** 有声内容当专辑（M3 接内容源后由发现页取代）。
  ///
  /// 搜索走 WBI（M0 S1 已验证）。注意搜索结果的 `videos` 字段可能虚标
  /// （实际 `view.pages` 只有 1 页），所以逐个候选实取验证「章节 ≥ 2」，
  /// 全不满足再退回已验证的兜底 bvid，
  /// 保证「发现页 → 详情 → 播放」主链路在弱网下也走得通。
  Future<AlbumBundle> pickSample({
    String keyword = '有声小说',
    String categoryId = 'rec',
  }) async {
    try {
      final res = await client.get(
        config.url(BiliPaths.searchType),
        query: {
          'search_type': 'video',
          'keyword': keyword,
          'page': 1,
          'page_size': 20,
        },
        useWbi: true,
        headers: {'Referer': config.searchHome},
      );
      final body = res.data is Map ? res.data['data'] : null;
      final list = body is Map ? body['result'] : null;
      final items = list is List ? list : const [];

      // 候选按「搜索标称分 P 数」降序，优先真·多 P
      final candidates = <Map<String, dynamic>>[
        for (final raw in items)
          if (raw is Map) Map<String, dynamic>.from(raw),
      ].map((m) {
        final videos = (m['videos'] as num?)?.toInt() ?? 1;
        return (videos, '${m['bvid'] ?? ''}');
      }).where((t) => t.$2.isNotEmpty).toList()
        ..sort((a, b) => b.$1.compareTo(a.$1));

      for (final (videos, bvid) in candidates.take(5)) {
        try {
          final bundle = await loadMultiPart(bvid, categoryId: categoryId);
          // 实取 ≥2 章才算多 P 专辑（videos 虚标时丢弃）
          if (bundle.chapters.length >= 2) {
            _log('[album] 取样命中 ${bundle.chapters.length} 章：$bvid'
                '（标称 $videos P）');
            return bundle;
          }
        } catch (e) {
          _log('[album] 候选 $bvid 取样失败：$e');
        }
      }
    } catch (e) {
      _log('[album] 取样失败，回退兜底 bvid：$e');
    }
    _log('[album] 使用兜底样本 $fallbackSampleBvid');
    return loadMultiPart(fallbackSampleBvid, categoryId: categoryId);
  }

  void _log(String msg) => log?.call(msg);
}
