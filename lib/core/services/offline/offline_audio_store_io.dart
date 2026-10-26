/// IO 平台实现（Android / 桌面）：`path_provider` 支持目录下的文件。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'audio_store_interface.dart';

/// audio_store.dart 的 IO 分派目标（条件导入按名字匹配）。
AudioStore platformAudioStore() => FileAudioStore();

class FileAudioStore implements AudioStore {
  Directory? _base;

  Future<Directory> _dir() async {
    final cached = _base;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}${Platform.pathSeparator}offline_audio');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _base = dir;
    return dir;
  }

  File _fileFor(Directory dir, String key) =>
      File('${dir.path}${Platform.pathSeparator}'
          '${Uri.encodeComponent(key)}.m4s');

  @override
  Future<String> save(String key, List<int> bytes) async {
    final dir = await _dir();
    final file = _fileFor(dir, key);
    await file.writeAsBytes(bytes, flush: true);
    return Uri.file(file.path).toString();
  }

  @override
  Future<bool> delete(String key) async {
    final dir = await _dir();
    final file = _fileFor(dir, key);
    if (!file.existsSync()) return false;
    await file.delete();
    return true;
  }

  @override
  Future<String?> playableUrl(String key) async {
    final dir = await _dir();
    final file = _fileFor(dir, key);
    return file.existsSync() ? Uri.file(file.path).toString() : null;
  }

  @override
  Future<int> sizeOf(String key) async {
    final dir = await _dir();
    final file = _fileFor(dir, key);
    return file.existsSync() ? file.lengthSync() : 0;
  }

  @override
  Future<void> clearAll() async {
    final dir = await _dir();
    if (dir.existsSync()) {
      await for (final e in dir.list()) {
        await e.delete(recursive: true);
      }
    }
  }

  @override
  String get locationLabel => '应用私有目录 / offline_audio';
}
