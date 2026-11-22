import 'dart:typed_data';

Future<String> dictionaryDirectoryPath() =>
    throw UnsupportedError('当前平台不支持离线词库');

Future<void> writeDictionaryBytes(String fileName, List<int> bytes) =>
    throw UnsupportedError('当前平台不支持离线词库');

Future<String?> readDictionaryString(String fileName) =>
    throw UnsupportedError('当前平台不支持离线词库');

Future<Uint8List> readDictionaryBytes(String fileName) =>
    throw UnsupportedError('当前平台不支持离线词库');

Future<bool> dictionaryFileExists(String fileName) =>
    throw UnsupportedError('当前平台不支持离线词库');

Future<void> deleteDictionaryFile(String fileName) =>
    throw UnsupportedError('当前平台不支持离线词库');

Future<void> deleteDictionaryAll() =>
    throw UnsupportedError('当前平台不支持离线词库');
