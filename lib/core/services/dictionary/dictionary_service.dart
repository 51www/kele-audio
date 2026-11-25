import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../domain/dictionary_entry.dart';
import 'dictionary_file_store.dart';
import 'dictionary_pack_config.dart';
import 'dictionary_state_store.dart';

class DictionaryLookupResult {
  const DictionaryLookupResult({
    required this.query,
    required this.entries,
    required this.isPhrase,
  });

  final String query;
  final List<DictionaryEntry> entries;
  final bool isPhrase;
  bool get found => entries.isNotEmpty;
}

/// 离线词库：按需下载 zip → 校验 → 解包 → 懒加载索引 → 本地查询。
///
/// 查询完全在设备上进行，不发送任何选中的正文。
class DictionaryService extends ChangeNotifier {
  DictionaryService({
    required this.state,
    Dio? dio,
  }) : _dio = dio ?? Dio();

  final DictionaryStateStore state;
  final Dio _dio;

  bool downloading = false;
  int received = 0;
  int total = 0;
  String? error;

  Map<String, DictionaryEntry>? _entries;
  Map<String, String>? _aliases;

  bool get isInstalled => state.isInstalled;

  /// 切换词库类型；切换后查询走另一套本地文件，需分别下载。
  Future<void> switchMode(DictionaryMode mode) async {
    if (state.mode == mode || downloading) return;
    _entries = null;
    _aliases = null;
    await state.setMode(mode);
    notifyListeners();
  }

  Future<void> download() async {
    if (downloading) return;
    downloading = true;
    error = null;
    received = 0;
    total = 0;
    _cancel = CancelToken();
    notifyListeners();

    final mode = state.mode;
    final version = DictionaryPackConfig.versionFor(mode);
    final sources = DictionaryPackConfig.sourcesFor(mode);
    DioException? lastError;
    final attempts = <String>[];
    try {
      final dir = await dictionaryDirectoryPath(version);
      final tempName = DictionaryPackConfig.tempFileName;
      final temp = '$dir/$tempName';
      for (final url in sources) {
        try {
          await _dio.download(
            url,
            temp,
            cancelToken: _cancel,
            options: Options(responseType: ResponseType.bytes),
            onReceiveProgress: (count, length) {
              received = count;
              total = length > 0 ? length : 0;
              notifyListeners();
            },
          );
          final bytes = await readDictionaryBytes(version, tempName);
          _verify(bytes, mode);
          await _install(bytes, mode);
          await state.save(DictionaryInstallState(
            version: version,
            installedAt: DateTime.now(),
            size: bytes.length,
            sha256: sha256.convert(bytes).toString(),
          ));
          _entries = null;
          _aliases = null;
          downloading = false;
          notifyListeners();
          return;
        } on DioException catch (e) {
          if (e.type == DioExceptionType.cancel || _cancel?.isCancelled == true) {
            rethrow;
          }
          attempts.add('${Uri.parse(url).host}: ${e.response?.statusCode ?? e.type.name}');
          lastError = e;
          continue;
        } catch (e) {
          attempts.add('${Uri.parse(url).host}: $e');
          lastError ??= DioException(
            requestOptions: RequestOptions(path: url),
            error: e,
          );
          continue;
        }
      }
      throw lastError ??
          StateError('词库下载失败：所有源均不可用');
    } on DioException catch (e) {
      if (e.type != DioExceptionType.cancel) {
        error = '词库下载失败：${e.message ?? e.error ?? e.type.name}';
        if (attempts.isNotEmpty) {
          error = '$error\n已尝试：${attempts.take(3).join('；')}';
        }
      }
    } catch (e) {
      error = '词库安装失败：$e';
      if (attempts.isNotEmpty) {
        error = '$error\n已尝试：${attempts.take(3).join('；')}';
      }
    } finally {
      downloading = false;
      notifyListeners();
    }
  }

  CancelToken? _cancel;

  void cancelDownload() => _cancel?.cancel('user_cancel');

  void _verify(Uint8List bytes, DictionaryMode mode) {
    final expected = DictionaryPackConfig.expectedSha256For(mode);
    if (expected == null) return;
    final actual = sha256.convert(bytes).toString();
    if (actual != expected) {
      throw StateError('词库校验失败（sha256 不匹配）');
    }
  }

  Future<void> _install(Uint8List bytes, DictionaryMode mode) async {
    final isZip = bytes.length > 2 && bytes[0] == 0x50 && bytes[1] == 0x4b;
    final Map<String, dynamic> payload;
    if (isZip) {
      payload = _readZipPack(bytes);
    } else {
      final raw = utf8.decode(bytes, allowMalformed: true).trimLeft();
      payload = raw.startsWith('{')
          ? parseJsonPack(raw, mode)
          : parseCsvPack(raw, mode);
    }
    await writeDictionaryBytes(
      DictionaryPackConfig.versionFor(mode),
      DictionaryPackConfig.innerFileName,
      utf8.encode(jsonEncode(payload)),
    );
  }

  Map<String, dynamic> _readZipPack(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final packed = archive.files.firstWhere(
      (file) => file.name.endsWith(DictionaryPackConfig.innerFileName),
      orElse: () => throw StateError('词库包缺少 dict.json'),
    );
    final decoded = jsonDecode(utf8.decode(packed.content as List<int>));
    if (decoded is! Map ||
        decoded['entries'] is! Map ||
        decoded['version'] == null) {
      throw StateError('词库文件格式不正确');
    }
    return Map<String, dynamic>.from(decoded);
  }

  /// 兼容两种 JSON：我们生成的 `entries/aliases`，以及 ECDICT 裁剪版
  /// `words/lemmas`（word -> {ph, tr}，lemmas 为「变形 -> 原型」）。
  static Map<String, dynamic> parseJsonPack(String raw, DictionaryMode mode) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw StateError('词库 JSON 格式不正确');

    final rawEntries = decoded['entries'];
    if (rawEntries is Map) {
      return Map<String, dynamic>.from(decoded);
    }

    final words = decoded['words'];
    if (words is! Map) throw StateError('词库 JSON 缺少 words 字段');
    final entries = <String, Map<String, String>>{};
    words.forEach((key, value) {
      if (key is! String || value is! Map) return;
      final translation = value['tr']?.toString().replaceAll(r'\n', '\n').trim() ?? '';
      if (translation.isEmpty) return;
      final word = key.trim().toLowerCase();
      if (word.isEmpty) return;
      entries[word] = <String, String>{
        'word': word,
        'translation': translation,
        'pos': '',
        'phonetic': value['ph']?.toString() ?? '',
      };
    });
    if (entries.isEmpty) throw StateError('词库 JSON 没有解析出词条');

    final aliases = <String, String>{};
    final lemmas = decoded['lemmas'];
    if (lemmas is Map) {
      lemmas.forEach((key, value) {
        if (key is String && value is String && key.isNotEmpty && value.isNotEmpty) {
          aliases[key.trim().toLowerCase()] = value.trim().toLowerCase();
        }
      });
    }
    return <String, dynamic>{
      'version': DictionaryPackConfig.versionFor(mode),
      'entries': entries,
      'aliases': aliases,
    };
  }

  static Map<String, dynamic> parseCsvPack(String raw, DictionaryMode mode) {
    final lines = raw.split('\n');
    if (lines.isEmpty) throw StateError('词库文件为空');
    final header = _parseCsvLine(lines.first.replaceAll('\r', ''));
    int column(String name) => header.indexOf(name);
    final wordIndex = column('word');
    final translationIndex = column('translation');
    final posIndex = column('pos');
    final phoneticIndex = column('phonetic');
    if (wordIndex < 0 || translationIndex < 0) {
      throw StateError('不是 ECDICT CSV：缺少 word/translation 列');
    }

    final entries = <String, Map<String, String>>{};
    for (final rawLine in lines.skip(1)) {
      final line = rawLine.replaceAll('\r', '');
      if (line.trim().isEmpty) continue;
      final cells = _parseCsvLine(line);
      if (cells.length <= translationIndex) continue;
      final word = cells[wordIndex].trim().toLowerCase();
      final translation = cells[translationIndex].replaceAll(r'\n', '\n').trim();
      if (word.isEmpty || translation.isEmpty) continue;
      entries[word] = <String, String>{
        'word': word,
        'translation': translation,
        'pos': posIndex >= 0 && cells.length > posIndex ? cells[posIndex] : '',
        'phonetic': phoneticIndex >= 0 && cells.length > phoneticIndex
            ? cells[phoneticIndex]
            : '',
      };
    }
    if (entries.isEmpty) throw StateError('词库 CSV 没有解析出词条');
    return <String, dynamic>{
      'version': DictionaryPackConfig.versionFor(mode),
      'entries': entries,
      'aliases': <String, String>{},
    };
  }

  static List<String> _parseCsvLine(String line) {
    final result = <String>[];
    final buffer = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final char = line[i];
      if (inQuotes) {
        if (char == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            buffer.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          buffer.write(char);
        }
      } else if (char == '"') {
        inQuotes = true;
      } else if (char == ',') {
        result.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(char);
      }
    }
    result.add(buffer.toString());
    return result;
  }

  Future<void> ensureLoaded() async {
    if (_entries != null || !isInstalled) return;
    final version = DictionaryPackConfig.versionFor(state.mode);
    final raw = await readDictionaryString(version, DictionaryPackConfig.innerFileName);
    if (raw == null) {
      throw StateError('词库文件缺失，请重新下载');
    }
    final parsed = await compute(_parsePack, raw);
    final rawEntries = parsed['entries'] as Map;
    _entries = <String, DictionaryEntry>{};
    rawEntries.forEach((key, value) {
      if (key is! String || value is! Map) return;
      _entries![key] = DictionaryEntry.fromJson(Map<String, dynamic>.from(value));
    });
    final rawAliases = parsed['aliases'];
    _aliases = <String, String>{};
    if (rawAliases is Map) {
      rawAliases.forEach((key, value) {
        if (key is String && value is String) _aliases![key] = value;
      });
    }
  }

  Future<DictionaryLookupResult> lookup(String text) async {
    final query = _normalize(text);
    await ensureLoaded();
    final isPhrase = query.contains(' ');
    final entries = <DictionaryEntry>[];
    if (isPhrase) {
      final exact = _find(query);
      if (exact != null) entries.add(exact);
    }
    if (entries.isEmpty) {
      for (final word in query.split(' ').take(12)) {
        if (word.isEmpty) continue;
        final entry = _find(word);
        if (entry != null) entries.add(entry);
      }
    }
    return DictionaryLookupResult(
      query: text.trim(),
      entries: entries,
      isPhrase: isPhrase,
    );
  }

  DictionaryEntry? _find(String word) {
    final entries = _entries;
    if (entries == null) return null;
    var key = word.toLowerCase();
    key = _aliases?[key] ?? key;
    final direct = entries[key];
    if (direct != null) return direct;
    if (key.endsWith('s') && key.length > 3) {
      return entries[key.substring(0, key.length - 1)];
    }
    return null;
  }

  static String _normalize(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r"[^\p{L}\p{N}\s'-]", unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Future<void> uninstall() async {
    await cancelDownloadAndWait();
    _entries = null;
    _aliases = null;
    await deleteDictionaryAll(DictionaryPackConfig.versionFor(state.mode));
    await state.clear();
    notifyListeners();
  }

  Future<void> cancelDownloadAndWait() async {
    final token = _cancel;
    if (token == null || token.isCancelled) return;
    token.cancel('user_cancel');
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
}

Map<String, dynamic> _parsePack(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) return <String, dynamic>{};
  return <String, dynamic>{
    'entries': decoded['entries'] ?? <String, dynamic>{},
    'aliases': decoded['aliases'] ?? <String, dynamic>{},
  };
}
