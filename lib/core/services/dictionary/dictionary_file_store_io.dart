import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// 按词库版本隔离目录，切换精简/完整词库时互不覆盖。
Future<String> dictionaryDirectoryPath(String version) async {
  final base = await getApplicationDocumentsDirectory();
  final dir = Directory('${base.path}/dictionaries/$version');
  await dir.create(recursive: true);
  return dir.path;
}

Future<void> writeDictionaryBytes(
  String version,
  String fileName,
  List<int> bytes,
) async {
  final dir = await dictionaryDirectoryPath(version);
  await File('$dir/$fileName').writeAsBytes(bytes, flush: true);
}

Future<String?> readDictionaryString(String version, String fileName) async {
  final dir = await dictionaryDirectoryPath(version);
  final file = File('$dir/$fileName');
  if (!await file.exists()) return null;
  return file.readAsString();
}

Future<Uint8List> readDictionaryBytes(String version, String fileName) async {
  final dir = await dictionaryDirectoryPath(version);
  return File('$dir/$fileName').readAsBytes();
}

Future<bool> dictionaryFileExists(String version, String fileName) async {
  final dir = await dictionaryDirectoryPath(version);
  return File('$dir/$fileName').exists();
}

Future<void> deleteDictionaryFile(String version, String fileName) async {
  final dir = await dictionaryDirectoryPath(version);
  final file = File('$dir/$fileName');
  if (await file.exists()) await file.delete();
}

Future<void> deleteDictionaryAll(String version) async {
  final path = await dictionaryDirectoryPath(version);
  final dir = Directory(path);
  if (await dir.exists()) await dir.delete(recursive: true);
}
