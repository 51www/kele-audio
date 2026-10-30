import 'dart:io';

import 'package:crypto/crypto.dart';

/// 计算文件 SHA-256（仅 `dart:io` 平台可用：Android / 桌面）。
Future<String?> computeFileSha256(String filePath) async {
  final File file = File(filePath);
  if (!await file.exists()) return null;
  final List<int> bytes = await file.readAsBytes();
  return sha256.convert(bytes).toString().toLowerCase();
}
