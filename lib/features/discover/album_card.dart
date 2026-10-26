import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import '../../app/widgets/common.dart';
import '../../core/domain/album.dart';

/// 封面图（M3 任务 5：磁盘缓存由 `cached_network_image` →
/// `flutter_cache_manager` 负责，Web 端走 IndexedDB 文件系统，两端同源）。
///
/// 失败/空地址一律回退「主题渐变 + 首字」占位，断网时不白框。
///
/// Web 预览例外：浏览器不能直连 B 站 CDN（无外网/跨域），封面改走
/// `tool/dev_proxy.mjs` 的 `/img?u=` 反代（与 M2 音频 `/audio?u=` 同思路）；
/// 原生端直连。
class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    required this.url,
    required this.title,
    this.borderRadius,
  });

  final String url;
  final String title;
  final BorderRadius? borderRadius;

  /// Web 端把绝对地址改写成同源反代（**必须补成绝对地址**：
  /// `Image.network` 底层的 HttpClient shim 对相对地址静默失败，
  /// 实测一个请求都不发）；其他平台原样返回。
  static String resolveUrl(String url) {
    if (!kIsWeb || url.isEmpty) return url;
    final proxied = url.startsWith('/')
        ? url // 已是同源路径
        : '/img?u=${Uri.encodeComponent(url)}';
    return Uri.base.resolve(proxied).toString();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget placeholder() => _LetterCover(
          title: title,
          borderRadius: borderRadius,
        );

    final resolved = resolveUrl(url);
    if (resolved.isEmpty) return placeholder();
    // Web 端 flutter_cache_manager 的 IndexedDB 文件系统在部分环境不触发请求
    // （实测 playwright 无任何 /img 请求发出），预览环境直接走引擎网络层；
    // 原生端走 CachedNetworkImage 磁盘缓存（里程碑 ⑤ 的封面缓存主体）。
    final image = kIsWeb
        ? Image.network(
            resolved,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => placeholder(),
          )
        : CachedNetworkImage(
            imageUrl: resolved,
            fit: BoxFit.cover,
            // 列表图按显示宽度取图，别把 1920 原图塞进 190px 卡片
            memCacheWidth: 480,
            placeholder: (_, _) => placeholder(),
            errorWidget: (_, _, _) => placeholder(),
            fadeInDuration: const Duration(milliseconds: 200),
          );
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.zero,
      child: image,
    )._withBackground(scheme);
  }
}

extension on Widget {
  /// 图片底衬：加载中/失败时露出主题色渐变而不是黑底。
  Widget _withBackground(ColorScheme scheme) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.primary.withValues(alpha: 0.35),
              scheme.secondary.withValues(alpha: 0.25),
            ],
          ),
        ),
        child: this,
      );
}

class _LetterCover extends StatelessWidget {
  const _LetterCover({required this.title, this.borderRadius});

  final String title;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary.withValues(alpha: 0.85),
            scheme.secondary.withValues(alpha: 0.65),
          ],
        ),
        borderRadius: borderRadius,
      ),
      alignment: Alignment.center,
      child: Text(
        title.isEmpty ? '书' : title.characters.first,
        style: TextStyle(
          color: scheme.onPrimary,
          fontSize: 34,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// 发现页双列卡片：封面 + 标题 + UP + 一行元信息。
///
/// 元信息口径：合集卡片有章节数 → 「N 集」；搜索卡片章节虚标（`videos`
/// 常为 "null"）→ 不显示集数，改显示时长 + 播放量。
class AlbumCard extends StatelessWidget {
  const AlbumCard({super.key, required this.album, this.onTap});

  final Album album;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;

    return KeleCard(
      onTap: onTap,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CoverImage(
            url: album.coverUrl,
            title: album.title,
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(tokens.radiusMd - 1),
            ),
          )._fixedHeight(context),
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
                const SizedBox(height: 4),
                Text(
                  album.upName.isEmpty ? 'UP 主未知' : album.upName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.captionStyle,
                ),
                const SizedBox(height: 4),
                Text(
                  _metaLine(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.numStyle,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _metaLine() {
    final parts = <String>[
      if (album.chapterCount > 0) '${album.chapterCount} 集',
      if (album.totalDurationSec > 0) _fmtDur(album.totalDurationSec),
      if (album.playCount > 0) _fmtPlay(album.playCount),
    ];
    return parts.isEmpty ? '—' : parts.join(' · ');
  }

  static String _fmtDur(int sec) {
    if (sec >= 3600) {
      final h = sec / 3600;
      return h >= 10 ? '${h.round()} 小时' : '${h.toStringAsFixed(1)} 小时';
    }
    return '${(sec / 60).round()} 分钟';
  }

  static String _fmtPlay(int play) {
    if (play >= 100000000) return '${(play / 100000000).toStringAsFixed(1)} 亿播放';
    if (play >= 10000) return '${(play / 10000).toStringAsFixed(1)} 万播放';
    return '$play 播放';
  }
}

extension on Widget {
  /// 卡片内封面定高：双列网格列宽自适应，高度按 16:9 随宽度算。
  Widget _fixedHeight(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          return SizedBox(width: w, height: w * 9 / 16, child: this);
        },
      );
}
