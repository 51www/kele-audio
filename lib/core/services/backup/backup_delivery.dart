/// 备份文件「平台交付」统一入口（导出侧）。
///
/// - Web：Blob + `<a download>` 触发浏览器下载；
/// - 移动端（Android/iOS）：临时文件 + 系统分享面板；
/// - 桌面：另存为对话框（file_picker.saveFile 传 bytes）；
/// - 其他平台走 stub，保证条件导入处处可编译。
///
/// 返回 `false` = 用户在交付环节取消（未产生文件）；平台不支持则抛
/// [UnsupportedError]。
library;

export 'backup_delivery_stub.dart'
    if (dart.library.io) 'backup_delivery_io.dart'
    if (dart.library.js_interop) 'backup_delivery_web.dart';

/// 建议的备份文件名（`kele-audio-backup-20261103-1530.json`）。
String suggestedBackupFileName(DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'kele-audio-backup-'
      '${now.year}${two(now.month)}${two(now.day)}'
      '-${two(now.hour)}${two(now.minute)}.json';
}
