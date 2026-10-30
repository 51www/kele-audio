/// Web 等无 `dart:io` 平台：无法本地读文件计算哈希，返回 null（跳过校验不阻断）。
Future<String?> computeFileSha256(String filePath) async => null;
