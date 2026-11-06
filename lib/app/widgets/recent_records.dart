import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/data/daos.dart';
import '../../core/services/player/player_service.dart';
import '../../core/services/recent_records.dart';
import '../../features/discover/album_card.dart';
import '../theme/app_tokens.dart';

/// 一条记录的封面：44dp（3:4）或 32dp（续读条）。
///
/// 本地书暂无封面文件，用**类型角标占位**（TXT / EPUB / PDF / 网页），
/// 不留空白方块。
class RecentRecordCover extends StatelessWidget {
  const RecentRecordCover({super.key, required this.record, this.width = 44});

  final RecentRecord record;
  final double width;

  static const _radius = BorderRadius.all(Radius.circular(8));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasRemoteCover =
        record.kind == RecentRecordKind.listening || record.coverUrl.isNotEmpty;
    return SizedBox(
      width: width,
      child: AspectRatio(
        aspectRatio: 3 / 4,
        child: hasRemoteCover
            ? CoverImage(
                url: record.coverUrl,
                title: record.title,
                borderRadius: _radius,
              )
            : Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: _radius,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      scheme.primary.withValues(alpha: 0.85),
                      scheme.secondary.withValues(alpha: 0.65),
                    ],
                  ),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 3,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: 0.86),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      record.badgeLabel.isEmpty ? '书' : record.badgeLabel,
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: width < 40 ? 8 : 9,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

/// 听书统计页「最近记录」的一行：64dp 高，无卡片底 / 描边 / 阴影。
class RecentRecordTile extends StatelessWidget {
  const RecentRecordTile({super.key, required this.record, required this.onTap});

  final RecentRecord record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              RecentRecordCover(record: record, width: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.bodyStyle.copyWith(
                        fontSize: 14,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      record.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.captionStyle,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 书架顶部续读条：56dp 高，底部一条发丝线，不做卡片底、不做阴影。
class ContinueRecordBar extends StatelessWidget {
  const ContinueRecordBar({super.key, required this.record, required this.onTap});

  final RecentRecord record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = tokens.bodyStyle.copyWith(
      fontSize: 13.5,
      height: 1.3,
      fontWeight: FontWeight.w500,
      color: scheme.onSurface,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: 56,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: tokens.spaceMd),
                child: Row(
                  children: [
                    RecentRecordCover(record: record, width: 32),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              record.continueTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: labelStyle,
                            ),
                          ),
                          if (record.progressLabel.isNotEmpty)
                            Text(' · ${record.progressLabel}',
                                style: labelStyle),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Divider(height: 0.5, thickness: 0.5, color: tokens.hairlineColor),
      ],
    );
  }
}

/// 打开一条记录：阅读进阅读页对应进度；听书进播放页对应专辑与集。
void openRecentRecord(BuildContext context, RecentRecord record) {
  if (record.kind == RecentRecordKind.reading) {
    context.push('/reader/${record.id}');
    return;
  }
  final daos = context.read<Daos>();
  final player = context.read<PlayerService>();
  final album = daos.albums.get(record.id);
  if (album == null) {
    // 专辑元数据缺失（旧备份）：先去详情页补抓，再让用户点播放。
    context.push('/album/${record.id}');
    return;
  }
  final chapters = daos.chapters.byAlbum(record.id);
  var startIndex = chapters.indexWhere((c) => c.id == record.chapterId);
  if (startIndex < 0) startIndex = record.chapterPosition;
  context.push('/player');
  if (chapters.isNotEmpty && startIndex >= 0) {
    unawaited(
      player.playAlbum(
        album,
        chapters: chapters,
        startIndex: startIndex,
        startAt: Duration(seconds: record.positionSec),
      ),
    );
  } else {
    unawaited(player.playAlbum(album));
  }
}
