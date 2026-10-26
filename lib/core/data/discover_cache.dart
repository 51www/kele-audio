import 'dart:convert';

import '../api/key_value_store.dart';
import '../domain/album.dart';

/// 分类首页缓存（M3 任务 5）：KV 持久化，JSON 形如
/// `{saved_at, page, has_more, items: [Album.toJson…]}`。
///
/// TTL 语义（PRD §5.1.2 建议 30 分钟，具体值由内容配置 `cache_ttl_minutes` 下发）：
/// - 新鲜（age < TTL）→ 直接展示，不发网络请求（秒开）；
/// - 过期 → 默认拒收（调用方走网络）；`allowStale=true` 时照样返回并标记
///   `stale`，供断网场景「缓存兜底 + 离线提示」使用。
///
/// 时钟可注入（测试用），生产默认 `DateTime.now`。
class DiscoverPageCache {
  DiscoverPageCache(this.store, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  static const String keyPrefix = 'discover_cache:';

  final KeyValueStore store;
  final DateTime Function() _now;

  static String keyOf(String categoryId) => '$keyPrefix$categoryId';

  /// 读缓存。[ttl] 为空时不过期判定（永不过期，仅供测试）。
  DiscoverCachedPage? read(
    String categoryId, {
    Duration? ttl,
    bool allowStale = false,
  }) {
    final raw = store.getString(keyOf(categoryId));
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final savedAt = (map['saved_at'] as num?)?.toInt() ?? 0;
      final items = <Album>[
        for (final e in (map['items'] as List?) ?? const [])
          if (e is Map) Album.fromJson(Map<String, dynamic>.from(e)),
      ];
      if (items.isEmpty) return null;
      final age = _now().millisecondsSinceEpoch - savedAt;
      final stale = ttl != null && age >= ttl.inMilliseconds;
      if (stale && !allowStale) return null;
      return DiscoverCachedPage(
        items: items,
        page: (map['page'] as num?)?.toInt() ?? 1,
        hasMore: map['has_more'] as bool? ?? false,
        savedAt: savedAt,
        stale: stale,
      );
    } catch (_) {
      // 缓存损坏视为未命中
      return null;
    }
  }

  /// 覆盖写（每次成功的首页加载都整页覆盖，不做分页累积：
  /// 二级页离线兜底只需要「分类首页」这一页）。
  Future<void> save(
    String categoryId, {
    required List<Album> items,
    required bool hasMore,
    int page = 1,
  }) async {
    if (items.isEmpty) return;
    await store.setString(
      keyOf(categoryId),
      jsonEncode({
        'saved_at': _now().millisecondsSinceEpoch,
        'page': page,
        'has_more': hasMore,
        'items': [for (final a in items) a.toJson()],
      }),
    );
  }
}

/// 一次缓存命中。
class DiscoverCachedPage {
  const DiscoverCachedPage({
    required this.items,
    required this.page,
    required this.hasMore,
    required this.savedAt,
    required this.stale,
  });

  final List<Album> items;
  final int page;
  final bool hasMore;
  final int savedAt;

  /// true = 超过 TTL、仅作断网兜底展示。
  final bool stale;
}
