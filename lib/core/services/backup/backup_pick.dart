import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// 导入侧：系统选文件（Web / Android / 桌面统一走 file_picker）。
///
/// 返回文件字节；用户取消返回 null。
Future<Uint8List?> pickBackupFile() async {
  final result = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['json'],
    withData: true,
  );
  final file = result?.files.singleOrNull;
  if (file == null) return null;
  final bytes = file.bytes;
  if (bytes != null) return bytes;
  // 个别平台不回填 bytes，兜底读路径
  final path = file.path;
  if (path == null) return null;
  // file_picker 已把文件读入内存（withData），这里仅在异常场景兜底
  throw StateError('备份文件内容不可读');
}
