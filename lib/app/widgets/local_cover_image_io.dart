import 'dart:io';

import 'package:flutter/widgets.dart';

/// 本地书封面：铺满父容器（调用方负责 3:4 比例与圆角裁剪）。
///
/// 文件不存在/解码失败时直接返回 [placeholder]，不抛异常也不留白框。
Widget localCoverImage({
  required String path,
  required Widget placeholder,
}) {
  if (path.isEmpty) return placeholder;
  return Image.file(
    File(path),
    fit: BoxFit.cover,
    gaplessPlayback: true,
    filterQuality: FilterQuality.medium,
    errorBuilder: (_, _, _) => placeholder,
  );
}
