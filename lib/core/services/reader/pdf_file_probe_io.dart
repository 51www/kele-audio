import 'dart:io';

/// 原生端：返回 PDF 文件字节数；不存在/不可读时返回 -1。
class PdfFileProbe {
  const PdfFileProbe._();

  static int lengthOf(String path) {
    try {
      final file = File(path);
      return file.existsSync() ? file.lengthSync() : -1;
    } on FileSystemException {
      return -1;
    }
  }
}
