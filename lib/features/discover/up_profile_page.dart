import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/di.dart';
import '../../app/theme/app_tokens.dart';
import '../../app/widgets/common.dart';
import '../../core/api/bili_client.dart';
import '../../core/domain/album.dart';
import '../../core/domain/up_profile.dart';
import '../player/mini_player.dart';
import '../reader/reader_tts_mini_bar.dart';
import 'album_list_row.dart';
import 'album_card.dart';

/// 主播主页（M11，二级页）：UP 主资料 + 投稿作品列表。
///
/// 上下分区：
/// - 上半部分 UP 主基本信息（头像 + 名称 + 签名 + 数据），视觉与专辑页
///   上半部分一致（同一套 [AppTokens] 间距/字阶的裸布局）；
/// - 下半部分作品列表，直接复用搜索页的 [AlbumListRow]，点击任一作品
///   进入对应专辑页（`/album/:bvid`）。
class UpProfilePage extends StatefulWidget {
  const UpProfilePage({super.key, required this.mid});

  /// B 站 mid（由专辑页 `Album.upMid` 传入）。
  final int mid;

  @override
  State<UpProfilePage> createState() => _UpProfilePageState();
}

class _UpProfilePageState extends State<UpProfilePage> {
  UpProfile? _profile;
  final List<Album> _works = [];
  int _page = 0;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
    _scroll.addListener(() {
      if (!_hasMore || _loading || _loadingMore) return;
      if (_scroll.position.extentAfter > 400) return;
      _loadMore();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final source = context.read<AppServices>().upProfile;
    setState(() {
      _loading = true;
      _error = null;
    });

    // 资料与作品串行请求（全局 450ms 节流，勿并发）。
    UpProfile? profile;
    String? profileError;
    try {
      profile = await source.profile(widget.mid);
    } on BiliApiException catch (e) {
      profileError = e.message;
    } catch (e) {
      profileError = '$e';
    }

    UpWorksPage? works;
    String? worksError;
    try {
      works = await source.works(widget.mid, page: 1);
    } on BiliApiException catch (e) {
      worksError = e.message;
    } catch (e) {
      worksError = '$e';
    }

    if (!mounted) return;
    setState(() {
      _profile = profile;
      _works
        ..clear()
        ..addAll(works?.items ?? const []);
      _page = works?.page ?? 0;
      _hasMore = works?.hasMore ?? false;
      _loading = false;
      // 资料与作品都拿不到才算整体失败；只要有一方成功就正常展示。
      if (profile == null && works == null) {
        _error = worksError ?? profileError ?? '加载失败，稍后再试';
      }
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final source = context.read<AppServices>().upProfile;
      final next = await source.works(widget.mid, page: _page + 1);
      if (!mounted) return;
      setState(() {
        _works.addAll(next.items);
        _page = next.page;
        _hasMore = next.hasMore;
      });
    } on BiliApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _profile?.name ?? '主播主页';
    return Scaffold(
      appBar: AppBar(title: Text(title, maxLines: 1)),
      bottomNavigationBar: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TtsMiniPlayerSlot(alignToHomeBar: true),
          MiniPlayerSlot(alignToHomeBar: true),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final tokens = AppTokens.of(context);
    if (_works.isEmpty && _error != null) {
      return EmptyState(
        icon: Icons.cloud_off_rounded,
        title: '加载失败',
        message: _error ?? '网络不太给力，稍后再试',
        actionLabel: '重试',
        onAction: _load,
      );
    }

    return CustomScrollView(
      controller: _scroll,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(tokens.spaceMd),
            child: _profileCard(context, tokens),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spaceMd,
              0,
              tokens.spaceMd,
              tokens.spaceSm,
            ),
            child: SectionTitle('投稿作品'),
          ),
        ),
        if (_works.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: tokens.spaceMd,
                vertical: tokens.spaceLg,
              ),
              child: Text(
                '这位主播暂时没有可显示的投稿作品',
                style: tokens.captionStyle,
              ),
            ),
          )
        else
          SliverList.builder(
            itemCount: _works.length + (_hasMore || _loadingMore ? 1 : 0),
            itemBuilder: (context, i) {
              if (i >= _works.length) {
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
              return Padding(
                padding: EdgeInsets.only(bottom: tokens.spaceSm),
                child: AlbumListRow(album: _works[i]),
              );
            },
          ),
        SliverToBoxAdapter(child: SizedBox(height: tokens.spaceLg)),
      ],
    );
  }

  /// 上半部分：UP 主资料。布局语言与专辑页上半部分一致（封面位 + 右侧
  /// 信息列、titleStyle/bodyStyle/captionStyle、统一间距，裸布局不加卡片底）。
  Widget _profileCard(BuildContext context, AppTokens tokens) {
    final p = _profile;
    final name = p?.name ?? '主播 ${widget.mid}';
    final meta = <String>[
      if (p != null && p.fans > 0) '粉丝 ${_fmtCount(p.fans)}',
      if (p != null && p.archiveCount > 0) '投稿 ${p.archiveCount}',
    ];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(tokens.radiusMd),
          child: SizedBox(
            width: 110,
            height: 110,
            child: CoverImage(url: p?.face ?? '', title: name),
          ),
        ),
        SizedBox(width: tokens.spaceMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: tokens.titleStyle,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              if (meta.isNotEmpty) ...[
                SizedBox(height: tokens.spaceSm),
                Text(meta.join(' · '), style: tokens.captionStyle),
              ],
              if ((p?.sign ?? '').isNotEmpty) ...[
                SizedBox(height: tokens.spaceSm),
                Text(
                  p!.sign,
                  style: tokens.captionStyle,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  static String _fmtCount(int n) {
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }
}
