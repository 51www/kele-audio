// 本地封面渲染：Android/桌面走 `Image.file`，Web 端直接回退占位
// （本地书导入/阅读本来只在 Android 提供）。
export 'local_cover_image_io.dart'
    if (dart.library.js_interop) 'local_cover_image_web.dart';
