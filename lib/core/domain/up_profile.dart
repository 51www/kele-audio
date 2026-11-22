library;

import 'album.dart';

/// 主播（UP 主）资料（主播主页 M11）。
///
/// 与 [Album.upMid] 对应：主播页路由 `/up/:mid` 的 mid 即 B 站 `mid`。
/// 资料来自 `x/web-interface/card`（免 WBI、免风控），作品列表来自
/// `x/space/wbi/arc/search`（投稿视频，WBI 签名），每条作品就是一个
/// 多 P 专辑（bvid），点击复用 `/album/:bvid`。

/// UP 主资料摘要（card 接口）。
class UpProfile {
  const UpProfile({
    required this.mid,
    required this.name,
    this.face = '',
    this.sign = '',
    this.fans = 0,
    this.archiveCount = 0,
  });

  final int mid;
  final String name;

  /// 头像（绝对地址，由数据源做协议归一）。
  final String face;

  /// 个人签名。
  final String sign;
  final int fans;

  /// 投稿视频数（card 接口的 `archive_count`）。
  final int archiveCount;
}

/// 主播作品列表的一页。
///
/// 直接复用 [Album]：作品即投稿视频（bvid），与搜索页结果同构，
/// 可原样交给搜索结果行渲染并跳转到 `/album/:id`。
class UpWorksPage {
  const UpWorksPage({
    required this.items,
    required this.page,
    required this.hasMore,
  });

  final List<Album> items;
  final int page;
  final bool hasMore;
}
