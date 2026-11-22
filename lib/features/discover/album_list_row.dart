import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_tokens.dart';
import '../../app/widgets/common.dart';
import '../../core/domain/album.dart';
import 'album_card.dart';

/// 作品列表单行：横版封面 + 标题 + UP + 元信息。
///
/// 从搜索页（`search_page.dart`）提取，供搜索结果与主播主页作品列表共用，
/// 保证两处列表布局与跳转口径完全一致。点击跳转 `/album/:id`。
class AlbumListRow extends StatelessWidget {
  const AlbumListRow({super.key, required this.album});

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
