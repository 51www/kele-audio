import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/theme/app_tokens.dart';
import '../../app/widgets/common.dart';
import '../../core/api/api_config.dart';
import '../../core/api/bili_client.dart';
import 'discover_seed.dart';

/// Tab 1 发现页（PRD §5.1）。
///
/// M1 范围：顶部栏 + 分类 Tab + 双列卡片流骨架 + `core/api` 接口自检；
/// M3 接入真实内容源（搜索/合集聚合、分页、骨架屏、缓存）。
class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  String _categoryId = kDiscoverCategories.first.id;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final cards = seedFor(_categoryId);

    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: () async {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          if (context.mounted) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(const SnackBar(
                content: Text('M1 骨架阶段：内容将在 M3 接入后刷新'),
              ));
          }
        },
        child: ListView(
          padding: EdgeInsets.fromLTRB(0, 0, 0, tokens.spaceLg),
          children: [
            _buildHeader(context, tokens, scheme),
            const _ApiProbeCard(),
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spaceMd,
                tokens.spaceMd,
                tokens.spaceMd,
                tokens.spaceSm,
              ),
              child: Text(
                '按类型找内容',
                style: tokens.sectionStyle,
              ),
            ),
            _buildCategories(tokens, scheme),
            SizedBox(height: tokens.spaceMd),
            _buildGrid(tokens, scheme, cards),
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spaceMd,
                tokens.spaceMd,
                tokens.spaceMd,
                0,
              ),
              child: Center(
                child: Text(
                  '卡片为占位数据 · M3 接入 B 站真实内容',
                  style: tokens.captionStyle,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    AppTokens tokens,
    ColorScheme scheme,
  ) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spaceMd,
        tokens.spaceMd,
        tokens.spaceMd,
        0,
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              gradient: tokens.accentGradient,
              borderRadius: BorderRadius.circular(tokens.radiusMd),
            ),
            alignment: Alignment.center,
            child: Text(
              '可',
              style: TextStyle(
                color: scheme.onPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('可乐听书', style: tokens.titleStyle),
                Text('免登录 · 无广告 · 专注收听', style: tokens.captionStyle),
              ],
            ),
          ),
          IconButton(
            tooltip: '儿童模式 · M6 接入',
            onPressed: () => ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(const SnackBar(
                content: Text('儿童模式将在 M6 接入（主题皮肤 + 白名单内容）'),
              )),
            icon: const Icon(Icons.child_care_outlined),
          ),
        ],
      ),
    );
  }

  Widget _buildCategories(AppTokens tokens, ColorScheme scheme) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: tokens.spaceMd),
        itemCount: kDiscoverCategories.length,
        separatorBuilder: (_, _) => SizedBox(width: tokens.spaceSm),
        itemBuilder: (context, i) {
          final cat = kDiscoverCategories[i];
          final selected = cat.id == _categoryId;
          return InkWell(
            borderRadius: BorderRadius.circular(tokens.radiusPill),
            onTap: () => setState(() => _categoryId = cat.id),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: selected ? scheme.primary : scheme.surfaceContainer,
                borderRadius: BorderRadius.circular(tokens.radiusPill),
                border: Border.all(
                  color: selected ? scheme.primary : tokens.hairlineColor,
                ),
              ),
              child: Text(
                cat.label,
                style: tokens.bodyStyle.copyWith(
                  fontWeight: FontWeight.w700,
                  color: selected ? scheme.onPrimary : scheme.onSurface,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildGrid(
    AppTokens tokens,
    ColorScheme scheme,
    List<SeedAlbum> cards,
  ) {
    if (cards.isEmpty) {
      return const EmptyState(
        icon: Icons.inbox_outlined,
        title: '该分类暂无内容',
        message: '换个分类看看，或稍后下拉刷新重试。',
      );
    }
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.symmetric(horizontal: tokens.spaceMd),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: tokens.spaceMd,
        crossAxisSpacing: tokens.spaceMd,
        childAspectRatio: 0.66,
      ),
      itemCount: cards.length,
      itemBuilder: (context, i) => _AlbumCard(
        album: cards[i],
        index: i,
        onTap: () => context.push('/album/${cards[i].id}'),
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({
    required this.album,
    required this.index,
    required this.onTap,
  });

  final SeedAlbum album;
  final int index;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;

    // 封面占位：用主题色派生的渐变 + 首字（真实封面图 M3 接入）
    final opacity = 0.9 - (index % 4) * 0.14;

    return KeleCard(
      onTap: onTap,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    scheme.primary.withValues(alpha: opacity),
                    scheme.secondary.withValues(alpha: opacity * 0.8),
                  ],
                ),
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(tokens.radiusMd - 1),
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                album.title.characters.first,
                style: TextStyle(
                  color: scheme.onPrimary,
                  fontSize: 40,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(tokens.spaceSm + 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  album.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.bodyStyle.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  album.upName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.captionStyle,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      '${album.chapters} 集',
                      style: tokens.numStyle,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        album.playCount,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.captionStyle,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────────────── 接口自检（M1）

enum _ProbeState { idle, running, ok, fail }

class _ApiProbeCard extends StatefulWidget {
  const _ApiProbeCard();

  @override
  State<_ApiProbeCard> createState() => _ApiProbeCardState();
}

class _ApiProbeCardState extends State<_ApiProbeCard> {
  _ProbeState _state = _ProbeState.idle;
  String? _summary;
  String? _brief;
  String? _error;
  String? _url;
  Map<String, String>? _headers;

  static String _stripHtml(String s) => s
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&amp;', '&')
      .trim();

  Future<void> _run() async {
    final client = context.read<BiliClient>();
    final config = context.read<ApiConfig>();
    setState(() {
      _state = _ProbeState.running;
      _error = null;
    });

    final sw = Stopwatch()..start();
    try {
      final res = await client.get(
        config.url(BiliPaths.searchType),
        query: {
          'search_type': 'video',
          'keyword': '有声小说',
          'page': 1,
          'page_size': 20,
        },
        useWbi: true,
        headers: {'Referer': config.searchHome},
      );
      sw.stop();
      final data = res.data is Map ? res.data['data'] : null;
      final list = (data is Map ? data['result'] : null) as List? ?? const [];
      final titles = list
          .take(3)
          .map((e) => _stripHtml('${(e as Map)['title'] ?? ''}'))
          .where((t) => t.isNotEmpty)
          .toList();
      final trace = client.lastTrace;
      if (!mounted) return;
      setState(() {
        _state = _ProbeState.ok;
        _summary =
            'HTTP ${res.statusCode} · ${sw.elapsedMilliseconds}ms · 命中 ${list.length} 条'
            '${data is Map && data['numResults'] != null ? ' / 共 ${data['numResults']}' : ''}';
        _brief = titles.isEmpty
            ? (trace?.bodyBrief ?? '')
            : '命中：${titles.join('　·　')}';
        _url = trace?.url;
        _headers = trace?.headers;
      });
    } on BiliApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _ProbeState.fail;
        _error = '${e.code ?? ''} ${e.message}'.trim();
        _url = client.lastTrace?.url;
        _headers = client.lastTrace?.headers;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _ProbeState.fail;
        _error = '$e';
        _url = client.lastTrace?.url;
        _headers = client.lastTrace?.headers;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final config = context.read<ApiConfig>();

    final statusChip = switch (_state) {
      _ProbeState.idle => const StageTag('未发起'),
      _ProbeState.running => const StageTag('请求中…', tone: StageTone.accent),
      _ProbeState.ok => const StageTag('返回成功', tone: StageTone.done),
      _ProbeState.fail => StageTag('失败', tone: StageTone.accent),
    };

    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spaceMd,
        tokens.spaceMd,
        tokens.spaceMd,
        0,
      ),
      child: KeleCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.api_rounded,
                    size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(child: Text('接口自检 · core/api', style: tokens.sectionStyle)),
                statusChip,
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'UA / Referer / Cookie 由统一 Dio 注入 · ${config.describe()}',
              style: tokens.captionStyle,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton(
                  onPressed: _state == _ProbeState.running ? null : _run,
                  child: Text(
                    _state == _ProbeState.running ? '请求中…' : '发起 WBI 搜索请求',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '关键词「有声小说」',
                    style: tokens.captionStyle,
                  ),
                ),
              ],
            ),
            if (_summary != null) ...[
              const SizedBox(height: 12),
              Text(_summary!, style: tokens.numStyle),
            ],
            if (_brief != null && _brief!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                _brief!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: tokens.bodyStyle,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                '$_error',
                style: tokens.bodyStyle.copyWith(color: scheme.error),
              ),
              if (_state == _ProbeState.fail)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '提示：Web 预览走本地反代 tool/dev_proxy.mjs；'
                    '-412/-352 为风控，稍后重试即可。',
                    style: tokens.captionStyle,
                  ),
                ),
            ],
            if (_url != null) ...[
              const SizedBox(height: 12),
              Divider(color: tokens.hairlineColor),
              const SizedBox(height: 8),
              Text('请求 URL', style: tokens.captionStyle),
              const SizedBox(height: 2),
              Text(
                _url!,
                style: tokens.captionStyle.copyWith(
                  fontFamily: 'monospace',
                  fontSize: 11.5,
                ),
              ),
            ],
            if (_headers != null && _headers!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('实际请求头（core/api 注入）', style: tokens.captionStyle),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(tokens.radiusSm),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final e in _headers!.entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(
                          '${e.key}: ${e.value}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tokens.captionStyle.copyWith(
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
