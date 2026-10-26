import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/theme/app_tokens.dart';
import '../../app/widgets/common.dart';
import '../../core/api/content_config.dart';
import '../../core/api/discover_source.dart';
import '../../core/data/daos.dart';
import '../../core/data/discover_cache.dart';
import '../../core/domain/album.dart';
import 'album_card.dart';

/// 单分类信息流（M3 任务 3/4）：
/// 骨架屏 → 双列卡片流 → 下拉刷新 → 触底分页 → 错误态重试 / 断网缓存兜底。
///
/// 每个分类一个独立 State（发现页用 `IndexedStack` 挂载），
/// **访问过才创建、创建后保留滚动位置与已加载页**。
class CategoryFeed extends StatefulWidget {
  const CategoryFeed({super.key, required this.category, required this.ttl});

  final CategoryConfig category;

  /// 分类首页缓存 TTL（内容配置 `cache_ttl_minutes` 下发）。
  final Duration ttl;

  @override
  State<CategoryFeed> createState() => _CategoryFeedState();
}

class _CategoryFeedState extends State<CategoryFeed>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _scroll = ScrollController();

  final List<Album> _items = [];
  int _page = 1;
  bool _hasMore = false;
  bool _loading = false;
  bool _loadingMore = false;
  bool _stale = false;
  String? _error;

  @override
  bool get wantKeepAlive => true; // IndexedStack 之外再兜一层保活

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadInitial();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  // ----------------------------------------------------------------- 加载

  Future<void> _loadInitial() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final cache = context.read<DiscoverPageCache>();
    final fresh = cache.read(widget.category.id, ttl: widget.ttl);
    if (fresh != null) {
      setState(() {
        _items
          ..clear()
          ..addAll(fresh.items);
        _page = fresh.page;
        _hasMore = fresh.hasMore;
        _stale = false;
        _loading = false;
      });
      return;
    }

    try {
      final data = await context
          .read<DiscoverSource>()
          .fetchPage(widget.category, 1);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(data.items);
        _page = 1;
        _hasMore = data.hasMore;
        _stale = false;
        _loading = false;
      });
      await cache.save(
        widget.category.id,
        items: data.items,
        hasMore: data.hasMore,
      );
      await _cacheCards(data.items);
    } catch (e) {
      if (!mounted) return;
      // 断网/风控：过期缓存兜底展示 + 离线提示，不白屏
      final stale = cache.read(
        widget.category.id,
        ttl: widget.ttl,
        allowStale: true,
      );
      setState(() {
        _loading = false;
        if (stale != null) {
          _items
            ..clear()
            ..addAll(stale.items);
          _page = stale.page;
          _hasMore = false; // 离线态不翻页
          _stale = true;
          _error = null;
        } else {
          _error = '$e';
        }
      });
    }
  }

  /// 卡片落库：详情页离线秒开头部信息，`series:` 直达时也能拿到 upMid。
  Future<void> _cacheCards(List<Album> items) async {
    try {
      await context.read<Daos>().albums.upsertAll(items);
    } catch (_) {
      // 落库失败不影响浏览
    }
  }

  Future<void> _refresh() async {
    final cache = context.read<DiscoverPageCache>();
    try {
      final data = await context
          .read<DiscoverSource>()
          .fetchPage(widget.category, 1);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(data.items);
        _page = 1;
        _hasMore = data.hasMore;
        _stale = false;
        _error = null;
      });
      await cache.save(
        widget.category.id,
        items: data.items,
        hasMore: data.hasMore,
      );
      await _cacheCards(data.items);
    } catch (_) {
      if (!mounted) return;
      // 刷新失败保留现有内容（可能已过期），仅打标
      setState(() => _stale = true);
      rethrow;
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loadingMore || !_hasMore) return;
    if (_scroll.position.pixels >=
        _scroll.position.maxScrollExtent - 320) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final data = await context
          .read<DiscoverSource>()
          .fetchPage(widget.category, next);
      if (!mounted) return;
      final seen = _items.map((a) => a.id).toSet();
      setState(() {
        _items.addAll(data.items.where((a) => !seen.contains(a.id)));
        _page = next;
        _hasMore = data.hasMore;
        _loadingMore = false;
      });
      await _cacheCards(data.items);
    } catch (_) {
      if (!mounted) return;
      // 翻页失败不打断浏览：静默收起 loading，底部可再试
      setState(() => _loadingMore = false);
    }
  }

  // ----------------------------------------------------------------- 视图

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final tokens = AppTokens.of(context);

    if (_items.isEmpty && _error != null) {
      return EmptyState(
        icon: Icons.cloud_off_rounded,
        title: '加载失败',
        message: '网络不太给力，稍后重试试试。\n($_error)',
        actionLabel: '重试',
        onAction: () {
          setState(() => _error = null);
          _loadInitial();
        },
      );
    }
    if (_items.isEmpty && _loading) return _SkeletonGrid(tokens: tokens);
    if (_items.isEmpty) {
      return const EmptyState(
        icon: Icons.inbox_outlined,
        title: '该分类暂无内容',
        message: '换个分类看看，或稍后下拉刷新重试。',
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 双列卡片按列宽自适应行高（封面 16:9 + 文案区实高）
          final colW = (constraints.maxWidth - tokens.spaceMd * 3) / 2;
          final childAspect = colW / (colW * 9 / 16 + 100);
          return ListView(
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(
              tokens.spaceMd,
              tokens.spaceSm,
              tokens.spaceMd,
              tokens.spaceLg,
            ),
            children: [
              if (_stale) ...[
                const _OfflineBanner(),
                SizedBox(height: tokens.spaceSm),
              ],
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: tokens.spaceMd,
                  crossAxisSpacing: tokens.spaceMd,
                  childAspectRatio: childAspect,
                ),
                itemCount: _items.length,
                itemBuilder: (context, i) => AlbumCard(
                  album: _items[i],
                  onTap: () => _open(_items[i]),
                ),
              ),
              SizedBox(height: tokens.spaceMd),
              if (_loadingMore)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(8),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                  ),
                )
              else if (!_hasMore)
                Center(
                  child: Text(
                    _stale ? '离线模式 · 仅展示缓存内容' : '— 已经到底啦 —',
                    style: tokens.captionStyle,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  void _open(Album album) {
    context.push('/album/${album.id}');
  }
}

/// 断网/过期兜底提示条。
class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spaceMd,
        vertical: tokens.spaceSm,
      ),
      decoration: BoxDecoration(
        color: scheme.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(tokens.radiusSm),
        border: Border.all(color: scheme.error.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.wifi_off_rounded, size: 16, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '当前网络不可用，正在展示缓存内容',
              style: tokens.captionStyle.copyWith(color: scheme.error),
            ),
          ),
        ],
      ),
    );
  }
}

/// 骨架屏：2×3 张灰卡占位（静态，不引入永不停止的动画，避免
/// `pumpAndSettle` 卡死）。
class _SkeletonGrid extends StatelessWidget {
  const _SkeletonGrid({required this.tokens});

  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shimmer = scheme.onSurface.withValues(alpha: 0.06);
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
        tokens.spaceMd,
        tokens.spaceSm,
        tokens.spaceMd,
        tokens.spaceLg,
      ),
      physics: const AlwaysScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: tokens.spaceMd,
        crossAxisSpacing: tokens.spaceMd,
        childAspectRatio: 0.72,
      ),
      itemCount: 6,
      itemBuilder: (_, _) => Container(
        decoration: BoxDecoration(
          color: shimmer,
          borderRadius: BorderRadius.circular(tokens.radiusMd),
          border: Border.all(color: tokens.hairlineColor),
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(tokens.radiusSm),
                ),
              ),
            ),
            const SizedBox(height: 10),
            _line(width: double.infinity, color: shimmer, tokens: tokens),
            const SizedBox(height: 6),
            _line(width: 120, color: shimmer, tokens: tokens),
            const SizedBox(height: 6),
            _line(width: 80, color: shimmer, tokens: tokens),
          ],
        ),
      ),
    );
  }

  Widget _line({
    required double width,
    required Color color,
    required AppTokens tokens,
  }) =>
      Container(
        width: width,
        height: 12,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(6),
        ),
      );
}
