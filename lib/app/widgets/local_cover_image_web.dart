import 'package:flutter/widgets.dart';

/// Web 端占位实现：本地书封面只存在于设备文件系统，浏览器一律回退占位。
Widget localCoverImage({
  required String path,
  required Widget placeholder,
}) => placeholder;
