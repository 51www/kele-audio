import 'dart:typed_data';

/// Web 端占位实现：阅读功能仅 Android 提供（docs/reader-plan.md 非目标）。
/// 这里返回明确的不可用错误，调用方不会在 Web 端进入导入/阅读流程。
Future<Never> _unsupported() async =>
    throw UnsupportedError('本地书导入与阅读仅支持 Android 端');

Future<Object> readerBookDir(String id) => _unsupported();

Future<String> saveReaderBookFile(
  String id,
  Uint8List bytes, {
  String fileName = 'book.epub',
}) => _unsupported();

Future<Uint8List?> readReaderBookFile(String id, String fileName) async => null;

Future<bool> readerBookFileExists(String id, String fileName) async => false;

Future<void> deleteReaderBookDir(String id) async {}
