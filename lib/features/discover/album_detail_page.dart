import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/di.dart';
import '../../app/theme/app_tokens.dart';
import '../../app/widgets/common.dart';
import '../../core/api/discover_source.dart';
import '../../core/domain/album.dart';
import '../../core/domain/records.dart';
import '../../core/services/offline/offline_cache_service.dart';
import '../../core/services/player/player_service.dart';
import '../../core/services/shelf_controller.dart';
import '../player/player_page.dart';
import 'album_card.dart';

/// 专辑详情页（PRD §5.2，M3）：
/// 播放全部 + 章节目录（长列表懒加载）+ 进度标记（读 `play_history`：
/// 未听 / 在听 x% / 已听完 ✓）+ 简介展开。
///
/// 数据来源（按优先级）：
/// 1. 本地 `album` / `chapter` 表（播放过/发现页卡片落库即有缓存，秒开）；
/// 2. [DiscoverSource.upNameOf] 补齐合集缺失的 UP 名（card 接口，KV 缓存）；
/// 3. [AlbumSource] 现取（多 P 用 `view.pages`，合集用 archives 列表）。
class AlbumDetailPage extends StatefulWidget {
  const AlbumDetailPage({super.key, required this.albumId});

  final String albumId;

  @override
  State<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

class _AlbumDetailPageState extends State<AlbumDetailPage> {
  Album? _album;
  List<Chapter> _chapters = const [];
  List<PlayHistory> _history = const [];
  bool _loading = true;
  bool _introExpanded = false;
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

    // 1) 本地缓存优先（发现页卡片已入库 / 播放过）
    var album = services.daos.albums.get(widget.albumId);
    var chapters = services.daos.chapters.byAlbum(widget.albumId);

    if (album == null || chapters.isEmpty) {
      // 2) 现取
      try {
        final bundle = await services.albums.load(
          id: widget.albumId,
          sourceType: _sourceType,
          categoryId: album?.categoryId ?? '',
          upMid: album?.upMid ?? 0,
        );
        album = bundle.album;
        chapters = bundle.chapters;
        await services.daos.albums.upsert(bundle.album);
        await services.daos.chapters.upsertAll(bundle.chapters);
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _error = '$e';
          _loading = false;
        });
        return;
      }
    }

    // 3) 合集接口的 meta 没有 UP 名：card 接口补齐（KV 缓存，失败静默）
    if (album.upName.isEmpty && album.upMid > 0) {
      final name = await services.discover.upNameOf(album.upMid);
      if (name.isNotEmpty) {
        album = album.copyWith(upName: name);
        await services.daos.albums.upsert(album);
      }
    }

    if (!mounted) return;
    setState(() {
      _album = album;
      _chapters = chapters;
      _history = services.daos.playHistory.forAlbum(widget.albumId);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('专辑详情')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

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

    return _detailView(context, tokens, album);
  }

  Widget _detailView(
    BuildContext context,
    AppTokens tokens,
    Album album,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final player = context.read<PlayerService>();
    // watch：收藏状态变化实时反映（加入/取消书架）
    final shelf = context.watch<ShelfController>();

    // 进度标记：chapterId → 历史；「在听」= 最近收听的章节
    final byChapter = {for (final h in _history) h.chapterId: h};
    final last = context.read<AppServices>().progress.lastOfAlbum(album.id);
    final playingChapterId = last?.chapterId ?? '';
    final totalSec = _chapters.fold<int>(0, (s, c) => s + c.durationSec);

    return Scaffold(
      appBar: AppBar(title: Text(album.title, maxLines: 1)),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spaceMd,
                tokens.spaceSm,
                tokens.spaceMd,
                0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(tokens.radiusMd),
                        child: SizedBox(
                          width: 110,
                          height: 146,
                          child: CoverImage(
                            url: album.coverUrl,
                            title: album.title,
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
                              [
                                if (_chapters.isNotEmpty)
                                  '${_chapters.length} 章',
                                if (totalSec > 0) '总时长 ${_fmtTotal(totalSec)}',
                                if (album.playCount > 0)
                                  '播放 ${_fmtPlay(album.playCount)}',
                              ].join(' · '),
                              style: tokens.captionStyle,
                            ),
                            if (last != null) ...[
                              const SizedBox(height: 8),
                              InfoChip(
                                '上次听到：${last.chapterTitle} '
                                '${fmtClock(Duration(seconds: last.positionSec))}',
                                tone: StageTone.accent,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (album.intro.isNotEmpty) ...[
                    SizedBox(height: tokens.spaceSm),
                    InkWell(
                      borderRadius: BorderRadius.circular(tokens.radiusSm),
                      onTap: () =>
                          setState(() => _introExpanded = !_introExpanded),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          album.intro,
                          maxLines: _introExpanded ? null : 3,
                          overflow:
                              _introExpanded ? null : TextOverflow.ellipsis,
                          style: tokens.captionStyle,
                        ),
                      ),
                    ),
                    Center(
                      child: Text(
                        _introExpanded ? '收起简介' : '展开简介',
                        style: tokens.captionStyle.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                  SizedBox(height: tokens.spaceMd),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _chapters.isEmpty
                              ? null
                              : () => player.playAlbum(album,
                                  chapters: _chapters),
                          icon: const Icon(Icons.play_arrow_rounded, size: 18),
                          label: const Text('播放全部'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final wasIn = shelf.has(album.id);
                          await shelf.toggle(album.id);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context)
                            ..hideCurrentSnackBar()
                            ..showSnackBar(SnackBar(
                              content: Text(wasIn
                                  ? '已移出书架：${album.title}'
                                  : '已加入书架：${album.title}'),
                              // M7 修复遗留：收藏/播放钮在页首操作区，
                              // Snackbar 悬浮避让不遮挡页面内容
                              margin: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                            ));
                        },
                        icon: Icon(
                          shelf.has(album.id)
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          size: 18,
                        ),
                        label: Text(shelf.has(album.id) ? '已收藏' : '收藏'),
                      ),
                    ],
                  ),
                  SizedBox(height: tokens.spaceSm),
                  // M8 离线缓存：整本入队（状态进度见 我的 → 离线缓存）
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _chapters.isEmpty
                          ? null
                          : () {
                              context.read<OfflineCacheService>().cacheAlbum(
                                    album,
                                    _chapters,
                                  );
                              ScaffoldMessenger.of(context)
                                ..hideCurrentSnackBar()
                                ..showSnackBar(SnackBar(
                                  content: Text(
                                      '已加入缓存队列：${album.title}（${_chapters.length} 章）'),
                                  margin:
                                      const EdgeInsets.fromLTRB(16, 0, 16, 96),
                                ));
                            },
                      icon: const Icon(Icons.download_for_offline_outlined,
                          size: 18),
                      label: const Text('整本缓存'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(0, tokens.spaceSm, 0, 0),
              child: SectionTitle(
                '章节目录',
                trailing: Text(
                  '已听 ${_finishedCount(byChapter)}/${_chapters.length}',
                  style: tokens.captionStyle,
                ),
              ),
            ),
          ),
          // 长列表懒加载：SliverList 按需构建（合集动辄 60+ 章不卡顿）
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => _chapterTile(
                context,
                tokens,
                album,
                i,
                byChapter[_chapters[i].id],
                playingChapterId,
              ),
              childCount: _chapters.length,
            ),
          ),
          SliverToBoxAdapter(child: SizedBox(height: tokens.spaceLg)),
        ],
      ),
    );
  }

  Widget _chapterTile(
    BuildContext context,
    AppTokens tokens,
    Album album,
    int i,
    PlayHistory? history,
    String playingChapterId,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final chapter = _chapters[i];
    final playing = chapter.id == playingChapterId;
    final percent = history?.percent ?? 0;
    final done = percent >= 90;

    final (mark, markColor) = switch ((done, percent)) {
      (true, _) => ('✓ 已听完', scheme.secondary),
      (false, > 0) => ('在听 $percent%', scheme.primary),
      _ => ('未听', scheme.onSurfaceVariant),
    };

    return Column(
      children: [
        if (i > 0)
          Divider(indent: 16, endIndent: 16, color: tokens.hairlineColor),
        ListTile(
          dense: true,
          leading: Text(
            (i + 1).toString().padLeft(2, '0'),
            style: tokens.numStyle.copyWith(
              color: playing || done ? scheme.primary : null,
            ),
          ),
          title: Text(
            chapter.title,
            style: tokens.bodyStyle.copyWith(
              fontWeight: playing ? FontWeight.w700 : null,
              color: playing ? scheme.primary : null,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(mark, style: tokens.captionStyle.copyWith(color: markColor)),
          trailing: Text(
            _fmtDur(chapter.durationSec),
            style: tokens.captionStyle,
          ),
          onTap: () {
            final player = context.read<PlayerService>();
            player.playAlbum(album, chapters: _chapters, startIndex: i);
            context.push('/player');
          },
        ),
      ],
    );
  }

  int _finishedCount(Map<String, PlayHistory> byChapter) {
    var n = 0;
    for (final c in _chapters) {
      if ((byChapter[c.id]?.percent ?? 0) >= 90) n++;
    }
    return n;
  }

  static String _fmtDur(int sec) {
    if (sec <= 0) return '--:--';
    return fmtClock(Duration(seconds: sec));
  }

  static String _fmtTotal(int sec) {
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    if (h <= 0) return '$m 分钟';
    return m <= 0 ? '$h 小时' : '$h 小时 $m 分';
  }

  static String _fmtPlay(int play) {
    if (play >= 10000) return '${(play / 10000).toStringAsFixed(1)} 万';
    return '$play';
  }
}
