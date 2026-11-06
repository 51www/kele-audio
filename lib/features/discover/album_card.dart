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
    Widget placeholder() =>
        _LetterCover(title: title, borderRadius: borderRadius);

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
      // 底衬必须在裁剪内部：放在外面会以直角矩形垫底，圆角四角露出背景色
      child: image._withBackground(scheme),
    );
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

/// 发现页双列卡片：16:9 封面（UP 主 / 集数叠在封面底部两角）+ 两行标题。
///
/// 元信息口径：合集卡片有章节数 → 「N 集」；没有章节数的搜索卡片依次回退
/// 到时长、播放量。叠层文字统一限制为 5 个字符，超出省略。
class AlbumCard extends StatelessWidget {
  const AlbumCard({super.key, required this.album, this.onTap});

  final Album album;
  final VoidCallback? onTap;

  /// 叠层两侧文字的最大字符数。
  static const int overlayMaxChars = 5;

  /// 卡片文案区（固定两行标题）高度，供网格行高预算共用，避免两处推算分叉。
  static double titleAreaHeight(AppTokens tokens) =>
      tokens.bodyStyle.fontSize! * _titleHeight * 2;

  static const double _titleHeight = 1.35;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(tokens.radiusSm);
    final leftLabel = _clamp(_leftLabel());
    final rightLabel = _clampOrNull(_rightLabel());

    // 布局节奏：卡内四周内缩 10px，封面固定 16:9（BoxFit.cover 裁切不变形），
    // UP 主/集数叠在封面底部左右两角，标题固定在封面下两行高。
    return KeleCard(
      onTap: onTap,
      padding: EdgeInsets.all(tokens.spaceSm + 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CoverImage(url: album.coverUrl, title: album.title),
                  Positioned(
                    left: 6,
                    right: 6,
                    bottom: 6,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Flexible(
                          child: _CoverChip(text: leftLabel, alignRight: false),
                        ),
                        if (rightLabel != null) ...[
                          const SizedBox(width: 6),
                          Flexible(
                            child: _CoverChip(
                              text: rightLabel,
                              alignRight: true,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: tokens.spaceSm),
          SizedBox(
            width: double.infinity,
            height: titleAreaHeight(tokens),
            child: Text(
              album.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: tokens.bodyStyle.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w700,
                height: _titleHeight,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _leftLabel() =>
      album.upName.trim().isEmpty ? '未知UP' : album.upName.trim();

  /// 右侧只叠集数；无章节数（搜索卡片虚标）时不显示，避免占用画面。
  String? _rightLabel() =>
      album.chapterCount > 0 ? '${album.chapterCount} 集' : null;

  /// 超过 [AlbumCard.overlayMaxChars] 个字符时，保留前 N-1 个 + 省略号
  /// （总长仍不超过上限）。
  static String _clamp(String value) {
    final chars = value.characters;
    if (chars.length <= overlayMaxChars) return value;
    return '${chars.take(overlayMaxChars - 1).join()}…';
  }

  static String? _clampOrNull(String? value) =>
      value == null ? null : _clamp(value);
}

/// 封面底部叠层小标签：半透明黑底 + 白字，保证任意封面上的可读性，
/// 同时只覆盖底部两角的小块画面。
class _CoverChip extends StatelessWidget {
  const _CoverChip({required this.text, required this.alignRight});

  final String text;
  final bool alignRight;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            height: 1.2,
            fontWeight: FontWeight.w600,
            shadows: [
              Shadow(
                color: Colors.black45,
                blurRadius: 3,
                offset: Offset(0, 1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 双列网格行高预算：卡内 10px 内边距 + 1px 描边 + 16:9 封面 + 8px 间距
/// + 固定两行标题 + 1px 余量。
double albumCardExtent(AppTokens tokens, double columnWidth) {
  final pad = tokens.spaceSm + 2;
  final coverWidth = columnWidth - pad * 2 - 2;
  return pad * 2 +
      2 +
      coverWidth * 9 / 16 +
      tokens.spaceSm +
      AlbumCard.titleAreaHeight(tokens) +
      1;
}
