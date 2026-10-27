import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../player/mini_player.dart';

import '../../app/di.dart';
import '../../app/theme/app_tokens.dart';
import '../../app/widgets/common.dart';
import '../../core/api/discover_source.dart';
import '../../core/domain/album.dart';
import 'album_card.dart';

/// 搜索页（M8 / PRD §5.1）：WBI 关键词搜索 + 本地历史 + 分页加载。
///
/// - `filterSearch` 口径：仅噪音词 + 60s 地板（用户主动意图优先，M8 决策）；
/// - 支持外部预置关键词（编辑精选专题卡跳转 `/search?q=...`，自动执行搜索）；
/// - 搜索历史存本地 KV（最近 10 条），可单删/清空。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, this.initialKeyword = ''});

  /// 编辑精选专题跳转时预置的关键词（非空则自动搜索）。
  final String initialKeyword;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();

  final List<Album> _items = [];
  String _keyword = '';
  int _page = 0;
  bool _hasMore = false;
  bool _loading = false;
  String? _error;

  static const String _historyKey = 'search_history';
  static const int _historyMax = 10;
  List<String> _history = [];

  @override
  void initState() {
    super.initState();
    _loadHistory();
    if (widget.initialKeyword.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _controller.text = widget.initialKeyword;
        _search(widget.initialKeyword.trim());
      });
    }
    _scroll.addListener(() {
      if (!_hasMore ||
          _loading ||
          _scroll.position.extentAfter > 400) {
        return;
      }
      _loadMore();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _loadHistory() {
    final kv = context.read<AppServices>().kv;
    final raw = kv.getString(_historyKey);
    setState(() {
      _history = raw == null || raw.isEmpty
          ? []
          : raw.split('\u{1}').where((e) => e.isNotEmpty).toList();
    });
  }

  Future<void> _saveHistory(String keyword) async {
    final kv = context.read<AppServices>().kv;
    _history
      ..remove(keyword)
      ..insert(0, keyword);
    if (_history.length > _historyMax) {
      _history = _history.sublist(0, _historyMax);
    }
    await kv.setString(_historyKey, _history.join('\u{1}'));
    if (mounted) setState(() {});
  }

  Future<void> _clearHistory() async {
    final kv = context.read<AppServices>().kv;
    await kv.remove(_historyKey);
    if (mounted) setState(() => _history = []);
  }

  Future<void> _search(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _keyword = kw;
      _items.clear();
      _page = 0;
      _hasMore = false;
      _loading = true;
      _error = null;
    });
    await _saveHistory(kw);
    await _fetch(reset: true);
  }

  Future<void> _loadMore() async {
    if (_keyword.isEmpty || _loading) return;
    setState(() => _loading = true);
    await _fetch(reset: false);
  }

  Future<void> _fetch({required bool reset}) async {
    final discover = context.read<DiscoverSource>();
    try {
      final res = await discover.searchAlbums(
        keyword: _keyword,
        page: reset ? 1 : _page + 1,
      );
      if (!mounted) return;
      setState(() {
        if (reset) _items.clear();
        final seen = _items.map((a) => a.id).toSet();
        _items.addAll(res.items.where((a) => seen.add(a.id)));
        _page = res.page;
        _hasMore = res.hasMore;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: TextField(
            controller: _controller,
            textInputAction: TextInputAction.search,
            onSubmitted: _search,
            decoration: InputDecoration(
              hintText: '搜专辑 / 关键词',
              isDense: true,
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(tokens.radiusPill),
                borderSide: BorderSide.none,
              ),
              filled: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      ),
      bottomNavigationBar: const MiniPlayerSlot(),
      body: _keyword.isEmpty ? _buildIdle(tokens, scheme) : _buildResults(tokens),
    );
  }

  // ------------------------------------------------------------ 空闲态：历史

  Widget _buildIdle(AppTokens tokens, ColorScheme scheme) {
    if (_history.isEmpty) {
      return const EmptyState(
        icon: Icons.search_rounded,
        title: '搜点什么吧',
        message: '输入关键词找想听的专辑，支持有声书 / 相声 / 评书 / 音乐等。',
      );
    }
    return ListView(
      padding: EdgeInsets.all(tokens.spaceMd),
      children: [
        Row(
          children: [
            Expanded(child: Text('搜索历史', style: tokens.sectionStyle)),
            TextButton(
              onPressed: _clearHistory,
              child: const Text('清空'),
            ),
          ],
        ),
        Wrap(
          spacing: tokens.spaceSm,
          runSpacing: tokens.spaceSm,
          children: [
            for (final h in _history)
              ActionChip(
                label: Text(h, style: tokens.captionStyle),
                onPressed: () {
                  _controller.text = h;
                  _search(h);
                },
              ),
          ],
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 结果态

  Widget _buildResults(AppTokens tokens) {
    if (_items.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty && _error != null) {
      return EmptyState(
        icon: Icons.cloud_off_rounded,
        title: '搜索失败',
        message: _error ?? '网络不太给力，稍后再试',
        actionLabel: '重试',
        onAction: () {
          setState(() => _error = null);
          _fetch(reset: true);
        },
      );
    }
    if (_items.isEmpty) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: '没有找到相关内容',
        message: '换个关键词试试，比如「三体有声书」「单田芳」。',
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: EdgeInsets.fromLTRB(
        tokens.spaceMd,
        tokens.spaceSm,
        tokens.spaceMd,
        tokens.spaceLg,
      ),
      itemCount: _items.length + (_hasMore || _loading ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= _items.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final album = _items[i];
        return Padding(
          padding: EdgeInsets.only(bottom: tokens.spaceSm),
          child: _SearchResultRow(album: album),
        );
      },
    );
  }
}

/// 搜索结果单行：横版封面 + 标题 + UP + 元信息。
class _SearchResultRow extends StatelessWidget {
  const _SearchResultRow({required this.album});

  final Album album;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return KeleCard(
      onTap: () => context.push('/album/${album.id}'),
      padding: EdgeInsets.all(tokens.spaceSm + 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(tokens.radiusSm),
            child: SizedBox(
              width: 108,
              height: 68,
              child: CoverImage(url: album.coverUrl, title: album.title),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  album.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.bodyStyle.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    if (album.upName.isNotEmpty) album.upName,
                    if (album.totalDurationSec > 0)
                      '${(album.totalDurationSec / 60).round()} 分钟',
                    if (album.chapterCount > 0) '${album.chapterCount} 集',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.captionStyle,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
