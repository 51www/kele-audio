import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/di.dart';
import '../../app/theme/app_tokens.dart';
import '../../app/widgets/common.dart';
import '../../core/domain/album.dart';
import '../../core/services/player/player_service.dart';
import '../player/player_page.dart';
import 'discover_seed.dart';

/// 专辑详情页（PRD §5.2）—— M2：真实章节数据 + 点击播放。
///
/// 数据来源（按优先级）：
/// 1. 本地 `album` / `chapter` 表（播放过即有缓存，秒开）；
/// 2. [AlbumSource] 现取（多 P 用 `view.pages`，合集用 archives 列表）。
///
/// 种子卡片（`m1-*`，M1 占位）仍显示占位结构，M3 接内容源后整体替换。
class AlbumDetailPage extends StatefulWidget {
  const AlbumDetailPage({super.key, required this.albumId});

  final String albumId;

  @override
  State<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

class _AlbumDetailPageState extends State<AlbumDetailPage> {
  Album? _album;
  List<Chapter> _chapters = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  SourceType get _sourceType =>
      widget.albumId.startsWith('series:') ||
              widget.albumId.startsWith('season:')
          ? SourceType.series
          : SourceType.multiPart;

  Future<void> _load() async {
    final services = context.read<AppServices>();

    // 1) 本地缓存优先
    final cached = services.daos.albums.get(widget.albumId);
    final cachedChapters = services.daos.chapters.byAlbum(widget.albumId);
    if (cached != null && cachedChapters.isNotEmpty) {
      setState(() {
        _album = cached;
        _chapters = cachedChapters;
        _loading = false;
      });
      return;
    }

    // 2) 种子占位（M1 卡片）
    final seed = kSeedAlbums.where((a) => a.id == widget.albumId).firstOrNull;
    if (seed != null) {
      setState(() {
        _album = null;
        _chapters = const [];
        _loading = false;
      });
      return;
    }

    // 3) 现取
    try {
      final bundle = await services.albums.load(
        id: widget.albumId,
        sourceType: _sourceType,
      );
      await services.daos.albums.upsert(bundle.album);
      await services.daos.chapters.upsertAll(bundle.chapters);
      if (!mounted) return;
      setState(() {
        _album = bundle.album;
        _chapters = bundle.chapters;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final seed = kSeedAlbums.where((a) => a.id == widget.albumId).firstOrNull;

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('专辑详情')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // 种子占位卡片：保持 M1 视觉 + 引导到 M2 真实样本
    if (seed != null) return _seedView(context, tokens, scheme, seed);

    final album = _album;
    if (album == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('专辑详情')),
        body: EmptyState(
          icon: Icons.error_outline_rounded,
          title: '专辑加载失败',
          message: _error ?? '没有找到这张专辑',
          actionLabel: '重试',
          onAction: () => setState(() {
            _loading = true;
            _error = null;
            _load();
          }),
        ),
      );
    }

    final player = context.read<PlayerService>();
    final history = context.read<AppServices>().progress.lastOfAlbum(album.id);
    final currentChapterIndex = history == null
        ? -1
        : _chapters.indexWhere((c) => c.id == history.chapterId);

    return Scaffold(
      appBar: AppBar(title: Text(album.title)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          tokens.spaceMd,
          tokens.spaceSm,
          tokens.spaceMd,
          tokens.spaceLg,
        ),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(tokens.radiusMd),
                child: SizedBox(
                  width: 110,
                  height: 146,
                  child: album.coverUrl.isEmpty
                      ? _placeholderCover(album, scheme)
                      : Image.network(
                          album.coverUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              _placeholderCover(album, scheme),
                        ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(album.title,
                        style: tokens.titleStyle,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 8),
                    Text(
                      album.upName.isEmpty ? 'UP 主未知' : album.upName,
                      style: tokens.bodyStyle,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_chapters.length} 章 · 播放 ${_playCount(album)}',
                      style: tokens.captionStyle,
                    ),
                    if (history != null) ...[
                      const SizedBox(height: 8),
                      StageTag(
                        '上次听到：${history.chapterTitle} '
                        '${fmtClock(Duration(seconds: history.positionSec))}',
                        tone: StageTone.accent,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: tokens.spaceMd),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => player.playAlbum(album, chapters: _chapters),
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('播放全部'),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: () => ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(const SnackBar(
                    content: Text('收藏将在 M4 书架接入'),
                  )),
                icon: const Icon(Icons.favorite_border_rounded, size: 18),
                label: const Text('收藏'),
              ),
            ],
          ),
          const SectionTitle('章节目录'),
          KeleCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < _chapters.length; i++) ...[
                  if (i > 0)
                    Divider(
                        indent: 16, endIndent: 16, color: tokens.hairlineColor),
                  ListTile(
                    dense: true,
                    leading: Text(
                      (i + 1).toString().padLeft(2, '0'),
                      style: tokens.numStyle.copyWith(
                        color: i == currentChapterIndex ? scheme.primary : null,
                      ),
                    ),
                    title: Text(
                      _chapters[i].title,
                      style: tokens.bodyStyle.copyWith(
                        fontWeight:
                            i == currentChapterIndex ? FontWeight.w700 : null,
                        color: i == currentChapterIndex ? scheme.primary : null,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text(
                      _fmtDur(_chapters[i].durationSec),
                      style: tokens.captionStyle,
                    ),
                    onTap: () {
                      player.playAlbum(
                        album,
                        chapters: _chapters,
                        startIndex: i,
                      );
                      context.push('/player');
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _seedView(
    BuildContext context,
    AppTokens tokens,
    ColorScheme scheme,
    SeedAlbum seed,
  ) {
    return Scaffold(
      appBar: AppBar(title: Text(seed.title)),
      body: ListView(
        padding: EdgeInsets.all(tokens.spaceMd),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 110,
                height: 146,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(tokens.radiusMd),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      scheme.primary.withValues(alpha: 0.9),
                      scheme.secondary.withValues(alpha: 0.7),
                    ],
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  seed.title.characters.first,
                  style: TextStyle(
                    color: scheme.onPrimary,
                    fontSize: 44,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(seed.title, style: tokens.titleStyle, maxLines: 3),
                    const SizedBox(height: 8),
                    Text(seed.upName, style: tokens.bodyStyle),
                    const SizedBox(height: 4),
                    Text(
                      '${seed.chapters} 集 · ${seed.durationLabel} · '
                      '播放 ${seed.playCount}',
                      style: tokens.captionStyle,
                    ),
                    const SizedBox(height: 10),
                    const StageTag('M1 占位数据', tone: StageTone.accent),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: tokens.spaceMd),
          KeleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('这是 M1 的占位卡片', style: tokens.sectionStyle),
                const SizedBox(height: 8),
                Text(
                  'M2 已接入真实播放核心。回到发现页顶部的「M2 播放样本」，'
                  '即可打开真实专辑（B 站多 P / 合集）并播放；'
                  'M3 接入内容源后，本页全部改为真实数据。',
                  style: tokens.bodyStyle,
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => context.go('/discover'),
                  icon: const Icon(Icons.explore_outlined, size: 18),
                  label: const Text('去发现页看真实样本'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholderCover(Album album, ColorScheme scheme) => Container(
        color: scheme.primary.withValues(alpha: 0.9),
        alignment: Alignment.center,
        child: Text(
          album.title.isEmpty ? '书' : album.title.characters.first,
          style: TextStyle(
            color: scheme.onPrimary,
            fontSize: 44,
            fontWeight: FontWeight.w800,
          ),
        ),
      );

  String _playCount(Album album) {
    if (album.playCount <= 0) return '-';
    if (album.playCount >= 10000) {
      return '${(album.playCount / 10000).toStringAsFixed(1)} 万';
    }
    return '${album.playCount}';
  }

  String _fmtDur(int sec) {
    if (sec <= 0) return '--:--';
    return fmtClock(Duration(seconds: sec));
  }
}
