/// Web 端：无本地文件路径，PDF 导入不支持。
class PdfFileProbe {
  const PdfFileProbe._();

  static int lengthOf(String path) => -1;
}
