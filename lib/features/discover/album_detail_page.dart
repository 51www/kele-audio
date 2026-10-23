import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import '../../app/widgets/common.dart';
import 'discover_seed.dart';

/// 专辑详情页（PRD §5.2）—— M1 占位；M3 接入真实章节数据，M2 负责播放。
class AlbumDetailPage extends StatelessWidget {
  const AlbumDetailPage({super.key, required this.albumId});

  final String albumId;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final album = kSeedAlbums.where((a) => a.id == albumId).firstOrNull;

    return Scaffold(
      appBar: AppBar(title: Text(album?.title ?? '专辑详情')),
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
                  album?.title.characters.first ?? '书',
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
                    Text(
                      album?.title ?? '专辑 $albumId',
                      style: tokens.titleStyle,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Text(album?.upName ?? 'UP 主待接入', style: tokens.bodyStyle),
                    const SizedBox(height: 4),
                    Text(
                      album == null
                          ? ''
                          : '${album.chapters} 集 · ${album.durationLabel} · 播放 ${album.playCount}',
                      style: tokens.captionStyle,
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const StageTag('M3 接入', tone: StageTone.accent),
                        const SizedBox(width: 8),
                        const StageTag('路由 /album/:id ✓'),
                      ],
                    ),
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
                  onPressed: () => ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(const SnackBar(
                      content: Text('播放将在 M2 播放核心接入'),
                    )),
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
                for (var i = 1; i <= 6; i++) ...[
                  if (i > 1) Divider(indent: 16, endIndent: 16, color: tokens.hairlineColor),
                  ListTile(
                    dense: true,
                    leading: Text(
                      i.toString().padLeft(2, '0'),
                      style: tokens.numStyle,
                    ),
                    title: Text(
                      '第 $i 章 · 章节列表由 M3 从 B 站分 P / 合集生成',
                      style: tokens.bodyStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text('${8 + i * 3}:00', style: tokens.captionStyle),
                    onTap: () => ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(const SnackBar(
                        content: Text('点击章节播放将在 M2 接入'),
                      )),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(height: tokens.spaceMd),
          Text(
            '收听进度标记（未听 / 在听 / 已听完）读取 play_history 表，M3 接入。',
            style: tokens.captionStyle,
          ),
        ],
      ),
    );
  }
}
