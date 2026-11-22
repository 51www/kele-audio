import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'dictionary_pack_config.dart';

Future<String> dictionaryDirectoryPath() async {
  final base = await getApplicationDocumentsDirectory();
  final dir = Directory('${base.path}/dictionaries/${DictionaryPackConfig.version}');
  await dir.create(recursive: true);
  return dir.path;
}

Future<void> writeDictionaryBytes(String fileName, List<int> bytes) async {
  final dir = await dictionaryDirectoryPath();
  await File('$dir/$fileName').writeAsBytes(bytes, flush: true);
}

Future<String?> readDictionaryString(String fileName) async {
  final dir = await dictionaryDirectoryPath();
  final file = File('$dir/$fileName');
  if (!await file.exists()) return null;
  return file.readAsString();
}

Future<Uint8List> readDictionaryBytes(String fileName) async {
  final dir = await dictionaryDirectoryPath();
  return File('$dir/$fileName').readAsBytes();
}

Future<bool> dictionaryFileExists(String fileName) async {
  final dir = await dictionaryDirectoryPath();
  return File('$dir/$fileName').exists();
}

Future<void> deleteDictionaryFile(String fileName) async {
  final dir = await dictionaryDirectoryPath();
  final file = File('$dir/$fileName');
  if (await file.exists()) await file.delete();
}

Future<void> deleteDictionaryAll() async {
  final path = await dictionaryDirectoryPath();
  final dir = Directory(path);
  if (await dir.exists()) await dir.delete(recursive: true);
}
