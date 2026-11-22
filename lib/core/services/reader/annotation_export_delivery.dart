/// 划线导出的平台交付统一入口。
///
/// - 移动：临时文件 + 系统分享面板；
/// - 桌面：另存为对话框；
/// - Web：浏览器下载。
library;

export 'annotation_export_delivery_stub.dart'
    if (dart.library.io) 'annotation_export_delivery_io.dart'
    if (dart.library.js_interop) 'annotation_export_delivery_web.dart';
