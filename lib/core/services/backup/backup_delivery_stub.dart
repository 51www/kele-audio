import 'dart:typed_data';

/// 平台兜底实现：不支持导出的平台直接抛错（页面捕获后给提示）。
Future<bool> deliverBackupFile(String fileName, Uint8List bytes) async {
  throw UnsupportedError('当前平台不支持导出备份文件');
}
