import 'dart:typed_data';

Future<bool> deliverAnnotationFile({
  required String fileName,
  required Uint8List bytes,
  required String mimeType,
}) async {
  throw UnsupportedError('当前平台不支持导出划线');
}
