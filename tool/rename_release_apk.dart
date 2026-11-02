// tool/rename_release_apk.dart
//
// 构建后把 Flutter Android 产物按 pubspec.yaml 的版本号重命名。
// 跨平台通用（Windows / macOS / Linux，只要装了 Flutter，`dart` 即可用）。
//
// 用法（在仓库根目录，先执行 flutter build）：
//   flutter build apk --release --split-per-abi && dart run tool/rename_release_apk.dart
//   flutter build appbundle --release && dart run tool/rename_release_apk.dart
//
// 重命名规则：
//   app-arm64-v8a-release.apk   -> kele-music-<version>-android-arm64-v8a.apk
//   app-armeabi-v7a-release.apk -> kele-music-<version>-android-armeabi-v7a.apk
//   app-x86_64-release.apk      -> kele-music-<version>-android-x86_64.apk
//   app-release.aab             -> kele-music-<version>-android.aab

import 'dart:io';

String _joinAll(String root, List<String> parts) {
  var path = root;
  for (final part in parts) {
    path = '${path}${Platform.pathSeparator}$part';
  }
  return path;
}

String _baseName(String path) => path.split(Platform.pathSeparator).last;

String? _parseVersion(String yaml) {
  for (final line in yaml.split('\n')) {
    final t = line.trim();
    if (t.startsWith('version:')) {
      final m = RegExp(r'(\d+\.\d+\.\d+)').firstMatch(t);
      if (m != null) return m.group(1);
    }
  }
  return null;
}

String _abiOf(String baseNameWithoutExt) {
  if (baseNameWithoutExt.contains('arm64-v8a')) return 'arm64-v8a';
  if (baseNameWithoutExt.contains('armeabi-v7a')) return 'armeabi-v7a';
  if (baseNameWithoutExt.contains('x86_64')) return 'x86_64';
  return 'universal';
}

void main(List<String> args) {
  final repoRoot = File(Platform.script.toFilePath()).parent.parent.path;
  final pubspec = File(_joinAll(repoRoot, ['pubspec.yaml']));
  if (!pubspec.existsSync()) {
    stderr.writeln('找不到 pubspec.yaml，请在仓库根目录运行本脚本。');
    exit(1);
  }
  final version = _parseVersion(pubspec.readAsStringSync());
  if (version == null) {
    stderr.writeln('无法从 pubspec.yaml 解析版本号。');
    exit(1);
  }

  final apkDir = Directory(
      _joinAll(repoRoot, ['build', 'app', 'outputs', 'flutter-apk']));
  final aabDir = Directory(
      _joinAll(repoRoot, ['build', 'app', 'outputs', 'bundle', 'release']));

  var renamed = 0;

  if (apkDir.existsSync()) {
    for (final ent in apkDir.listSync().whereType<File>()) {
      final name = _baseName(ent.path);
      if (!name.startsWith('app-') || !name.endsWith('.apk')) continue;
      final base = name.substring(0, name.length - 4); // 去掉 .apk
      final abi = _abiOf(base);
      final newName = 'kele-music-$version-android-$abi.apk';
      _rename(ent, _joinAll(apkDir.path, [newName]));
      renamed++;
    }
  }

  if (aabDir.existsSync()) {
    for (final ent in aabDir.listSync().whereType<File>()) {
      final name = _baseName(ent.path);
      if (!name.startsWith('app-') || !name.endsWith('.aab')) continue;
      final newName = 'kele-music-$version-android.aab';
      _rename(ent, _joinAll(aabDir.path, [newName]));
      renamed++;
    }
  }

  if (renamed == 0) {
    print('未找到可重命名的产物（先执行 flutter build apk/appbundle --release）。');
  } else {
    print('完成：共重命名 $renamed 个文件，版本 $version。');
  }
}

void _rename(File file, String newPath) {
  try {
    file.renameSync(newPath);
    print('  ${_baseName(file.path)} -> ${_baseName(newPath)}');
  } catch (e) {
    stderr.writeln('  重命名失败 ${file.path}: $e');
  }
}
