import '../domain/album.dart';
import '../domain/up_profile.dart';
import 'api_config.dart';
import 'bili_client.dart';
import 'discover_source.dart';

/// 主播主页数据源（M11）：UP 主资料 + 投稿作品列表。
///
/// 约束（同 [DiscoverSource]）：一切请求走 [BiliClient]（450ms 节流 / WBI /
/// 阶梯退避），**串行发起**；B 站接口路径全部集中在 [BiliPaths]。
///
/// - 资料：`x/web-interface/card`（免 WBI 免风控），每次现取、失败返回 null；
/// - 作品：`x/space/wbi/arc/search`（需 WBI，匿名易被风控），每条投稿映射成
///   一个多 P [Album]（bvid），与搜索页结果同构，点击复用 `/album/:bvid`。
class UpProfileSource {
  UpProfileSource({
    required this.client,
    required this.config,
    this.log,
  });

  final BiliClient client;
  final ApiConfig config;
  final void Function(String message)? log;

  /// arc/search 每页条数（B 站常规 20/30，取 20 稳）。
  static const int pageSize = 20;

  void _log(String msg) => log?.call('[up-profile] $msg');

  /// mid → UP 主资料。失败返回 null（由页面展示错误/降级态）。
  Future<UpProfile?> profile(int mid) async {
    if (mid <= 0) return null;
    try {
      final res = await client.get(
        config.url(BiliPaths.userCard),
        query: {'mid': mid, 'photo': 'false'},
      );
      final body = res.data is Map ? res.data['data'] : null;
      final card = body is Map ? body['card'] : null;
      if (card is! Map) return null;

      final name = _stripHtml('${card['name'] ?? ''}');
      if (name.isEmpty) return null;
      return UpProfile(
        mid: mid,
        name: name,
        face: DiscoverSource.normalizePic('${card['face'] ?? ''}'),
        sign: _stripHtml('${card['sign'] ?? ''}'),
        fans: _toInt(card['fans']),
        archiveCount: _toInt(body['archive_count'] ?? card['archive_count']),
      );
    } catch (e) {
      _log('profile $mid failed: $e');
      return null;
    }
  }

  /// 投稿作品列表（分页）。失败抛异常交页面展示错误态。
  ///
  /// 请求串行（不要在 UI 侧并发调用）：`arc/search` 命中风控时由 [BiliClient]
  /// 统一退避/缓解；仍失败则向上抛 [BiliApiException]。
  Future<UpWorksPage> works(int mid, {int page = 1}) async {
    if (mid <= 0) return UpWorksPage(items: const [], page: page, hasMore: false);
    final res = await client.get(
      config.url(BiliPaths.spaceArcSearch),
      query: {
        'mid': mid,
        'ps': pageSize,
        'pn': page,
        'order': 'pubdate',
      },
      useWbi: true,
      headers: {'Referer': '${config.homeBase}/space/$mid'},
    );
    final data = res.data is Map ? res.data['data'] : null;
    final list = data is Map ? data['list'] : null;
    final vlist = list is Map && list['vlist'] is List
        ? list['vlist'] as List
        : const [];

    final items = <Album>[];
    for (final raw in vlist) {
      if (raw is! Map) continue;
      final album = albumFromArc(
        Map<String, dynamic>.from(raw),
        fallbackMid: mid,
      );
      if (album != null) items.add(album);
    }

    final pageInfo = data is Map && data['page'] is Map
        ? data['page'] as Map
        : const {};
    final count = _toInt(pageInfo['count']);
    final hasMore = count > 0 ? page * pageSize < count : items.length >= pageSize;
    return UpWorksPage(items: items, page: page, hasMore: hasMore);
  }

  /// arc/search 投稿条目 → 专辑（供列表行与 `/album/:bvid` 跳转）。
  ///
  /// `arc/search` 的时长字段是 `length`（mm:ss）、发布时间是 `created`（秒），
  /// 归一成 search 项的键名后复用 [DiscoverSource.albumFromSearch]，保证
  /// 字段口径与搜索页一致。bvid 为空的无效条目返回 null。
  static Album? albumFromArc(
    Map<String, dynamic> raw, {
    int fallbackMid = 0,
  }) {
    return DiscoverSource.albumFromSearch({
      'bvid': raw['bvid'] ?? '',
      'title': raw['title'] ?? '',
      'pic': raw['pic'] ?? '',
      'author': raw['author'] ?? '',
      'duration': raw['length'] ?? raw['duration'] ?? '',
      'play': raw['play'] ?? 0,
      'pubdate': raw['created'] ?? raw['pubdate'] ?? 0,
      'mid': raw['mid'] ?? fallbackMid,
    });
  }

  static int _toInt(Object? v) => int.tryParse('${v ?? 0}') ?? 0;

  static String _stripHtml(String s) => s
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .trim();
}
