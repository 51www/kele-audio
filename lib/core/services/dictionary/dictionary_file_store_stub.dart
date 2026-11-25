import 'dart:typed_data';

Future<String> dictionaryDirectoryPath(String version) =>
    throw UnsupportedError('当前平台不支持离线词库');

Future<void> writeDictionaryBytes(
  String version,
  String fileName,
  List<int> bytes,
) => throw UnsupportedError('当前平台不支持离线词库');

Future<String?> readDictionaryString(String version, String fileName) =>
    throw UnsupportedError('当前平台不支持离线词库');

Future<Uint8List> readDictionaryBytes(String version, String fileName) =>
    throw UnsupportedError('当前平台不支持离线词库');

Future<bool> dictionaryFileExists(String version, String fileName) =>
    throw UnsupportedError('当前平台不支持离线词库');

Future<void> deleteDictionaryFile(String version, String fileName) =>
    throw UnsupportedError('当前平台不支持离线词库');

Future<void> deleteDictionaryAll(String version) =>
    throw UnsupportedError('当前平台不支持离线词库');
