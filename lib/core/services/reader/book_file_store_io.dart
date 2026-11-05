import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// 书籍文件落盘（IO 平台）：`documents/books/{id}/{fileName}`。
///
/// 三类来源在入库前都已统一为 EPUB，因此阅读/朗读管线只认一个文件。
Future<Directory> readerBookDir(String id) async {
  final base = await getApplicationDocumentsDirectory();
  return Directory('${base.path}${Platform.pathSeparator}books'
      '${Platform.pathSeparator}$id');
}

/// 保存书籍字节，返回落盘绝对路径。
Future<String> saveReaderBookFile(
  String id,
  Uint8List bytes, {
  String fileName = 'book.epub',
}) async {
  final dir = await readerBookDir(id);
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  final file = File('${dir.path}${Platform.pathSeparator}$fileName');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

/// 读取书籍字节；文件不存在时返回 null。
Future<Uint8List?> readReaderBookFile(String id, String fileName) async {
  final dir = await readerBookDir(id);
  final file = File('${dir.path}${Platform.pathSeparator}$fileName');
  if (!await file.exists()) return null;
  return file.readAsBytes();
}

/// 书籍文件是否存在。
Future<bool> readerBookFileExists(String id, String fileName) async {
  final dir = await readerBookDir(id);
  final file = File('${dir.path}${Platform.pathSeparator}$fileName');
  return file.exists();
}

/// 删除书籍目录（确认删除时调用，撤销只改元数据不删文件）。
Future<void> deleteReaderBookDir(String id) async {
  final dir = await readerBookDir(id);
  if (await dir.exists()) {
    await dir.delete(recursive: true);
  }
}
