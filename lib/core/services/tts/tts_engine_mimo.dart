import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'mimo_text_splitter.dart';
import 'mimo_tts_client.dart';
import 'tts_engine.dart';

/// 小米 MiMo 朗读引擎：短句切片 → 逐片合成 → 顺序播放。
///
/// 稳定性优先：
/// - 每片 ≤150 字（长输入会多读音节，宁可切短）；
/// - 播放当前片时后台预取后 2 片；
/// - 按 4.2 字/秒估算时长，实测超出 0.5~1.6 倍就拆成两片重试一次，仍异常则跳过并记日志；
/// - 单片音频缓存在临时目录（同一章重复听不再请求），换章清理；
/// - 暂停/停止/跳章立即取消在途请求。
class TtsMimoEngine implements TtsEngine {
  TtsMimoEngine({
    required this.apiKeyProvider,
    required this.paramsProvider,
    MimoTtsClient? client,
    this.splitter = const MimoTextSplitter(),
  }) : _client = client ?? MimoTtsClient();

  /// 每次请求前取当前 Key（设置页即时改动用得上）。
  final String Function() apiKeyProvider;

  /// 每次合成前取当前参数（音色切换可从下一片生效，不打断在播片）。
  final TtsParams Function() paramsProvider;

  final MimoTtsClient _client;
  final MimoTextSplitter splitter;

  static const int _maxCacheEntries = 24;
  static const double _charsPerSecond = 4.2;

  Player? _player;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<String>? _errorSub;
  Completer<void>? _pending;
  String? _lastError;
  TtsParams _params = const TtsParams();
  int _token = 0;
  int _cacheGen = 0;
  int _seq = 0;

  final Map<String, _ChunkAudio> _cache = {};
  final Map<String, Future<_ChunkAudio?>> _inflight = {};
  final Set<CancelToken> _cancels = {};

  File? _currentFile;

  @override
  String get id => 'mimo';

  void _ensurePlayer() {
    if (_player != null) return;
    MediaKit.ensureInitialized();
    final player = Player();
    _player = player;
    _completedSub = player.stream.completed.listen((done) {
      if (done) _finishPending();
    });
    _errorSub = player.stream.error.listen((message) {
      if (message.isEmpty) return;
      _lastError = message;
      _finishPending();
    });
  }

  /// 完成「本片播完」等待（防止 completed/error 双触发重复 complete）。
  void _finishPending() {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  double get _playbackRate => _params.rate.clamp(0.5, 3.0).toDouble();

  @override
  Future<void> start(TtsParams params) async {
    _params = params;
    _ensurePlayer();
    // MiMo 接口没有 speed 参数：语速用播放端倍速近似（音高会随倍速轻微变化）。
    try {
      await _player!.setRate(_playbackRate);
    } catch (e) {
      debugPrint('[tts:mimo] 设置倍速失败（沿用默认）：$e');
    }
  }

  @override
  void prefetch(String text) {
    if (apiKeyProvider().trim().isEmpty) return;
    final chunks = splitter.split(text);
    for (var i = 0; i < chunks.length && i < 2; i++) {
      _prewarm(chunks[i]);
    }
  }

  @override
  Future<void> speak(String text) async {
    if (apiKeyProvider().trim().isEmpty) {
      throw const TtsException(
        'config',
        '未配置 MiMo 朗读 API Key，请到「设置 → 本地书 · 听书 → MiMo 朗读」填写',
      );
    }
    final content = text.trim();
    if (content.isEmpty) return;
    _ensurePlayer();
    final token = _token;
    final chunks = splitter.split(content);
    if (chunks.isEmpty) return;

    var lastDoneAt = DateTime.now();
    try {
      for (var i = 0; i < chunks.length; i++) {
        if (token != _token) return;
        // 预热后两片：当前片播放期间后台合成，缩短段间空白。
        for (var j = i + 1; j <= i + 2 && j < chunks.length; j++) {
          _prewarm(chunks[j]);
        }
        final startedAt = DateTime.now();
        final chars = chunks[i].replaceAll(RegExp(r'\s+'), '').length;
        // 诊断日志：片号 + 字数 + 指纹（查重复）+ 与上一片播完的间隔（验证段间空白）。
        debugPrint(
          '[tts:mimo] 片段 ${i + 1}/${chunks.length} $chars字 '
          'fp=${sha1.convert(chunks[i].codeUnits).toString().substring(0, 6)} '
          '间隔=${i == 0 ? 0 : startedAt.difference(lastDoneAt).inMilliseconds}ms',
        );
        final pieces = await _resolveChunk(chunks[i], token);
        if (token != _token) return;
        for (final piece in pieces) {
          if (token != _token) return;
          await _play(piece, token);
        }
        lastDoneAt = DateTime.now();
        debugPrint(
          '[tts:mimo] 片段 ${i + 1} 播完，用时 '
          '${lastDoneAt.difference(startedAt).inMilliseconds}ms',
        );
      }
    } on TtsException catch (e) {
      if (e.code == 'cancelled' || token != _token) return;
      rethrow;
    }
  }

  void _prewarm(String chunk) {
    final key = _cacheKey(chunk);
    if (_cache.containsKey(key) || _inflight.containsKey(key)) return;
    unawaited(
      _getAudio(chunk, _token)
          .then<void>((_) {})
          .catchError((Object e) {
            debugPrint('[tts:mimo] 预取失败：${_shortError(e)}');
          }),
    );
  }

  /// 取一片音频；时长异常时拆成两片重试一次，仍异常则跳过。
  Future<List<_ChunkAudio>> _resolveChunk(String chunk, int token) async {
    final audio = await _getAudio(chunk, token);
    if (token != _token || audio == null) return const [];
    final expected = _expectedSeconds(chunk);
    if (_durationOk(audio, chunk)) return [audio];

    debugPrint(
      '[tts:mimo] 时长异常，拆分重试：${_stats(chunk, audio)}',
    );
    _dropFromCache(_cacheKey(chunk));
    final parts = splitter.splitInTwo(chunk);
    if (parts.length < 2) {
      debugPrint('[tts:mimo] 无法再拆分，跳过：${_stats(chunk, audio)}');
      return const [];
    }
    final result = <_ChunkAudio>[];
    for (final part in parts) {
      final sub = await _getAudio(part, token);
      if (token != _token) return result;
      if (sub == null) continue;
      if (_durationOk(sub, part)) {
        result.add(sub);
      } else {
        debugPrint('[tts:mimo] 重试仍异常，跳过：${_stats(part, sub)}');
        _dropFromCache(_cacheKey(part));
      }
    }
    debugPrint(
      '[tts:mimo] 拆分重试完成：原片预期 ${expected.toStringAsFixed(1)}s，'
      '保留 ${result.length}/${parts.length} 片',
    );
    return result;
  }

  bool _durationOk(_ChunkAudio audio, String text) {
    final actual = audio.duration;
    if (actual == null || actual <= Duration.zero) return true;
    final chars = text.replaceAll(RegExp(r'\s+'), '').length;
    if (chars < 20) return true; // 太短测不准，不拦
    final expected = _expectedSeconds(text);
    final ratio = (actual.inMilliseconds / 1000.0) / expected;
    return ratio >= 0.5 && ratio <= 1.6;
  }

  double _expectedSeconds(String text) =>
      text.replaceAll(RegExp(r'\s+'), '').length / _charsPerSecond;

  String _stats(String text, _ChunkAudio audio) {
    final chars = text.replaceAll(RegExp(r'\s+'), '').length;
    final actual = audio.duration?.inMilliseconds ?? 0;
    return '$chars 字，实测 ${(actual / 1000.0).toStringAsFixed(1)}s，'
        '预期 ${_expectedSeconds(text).toStringAsFixed(1)}s';
  }

  String _cacheKey(String chunk) {
    final voice = paramsProvider().voice.trim();
    return '${voice.isEmpty ? 'mimo_default' : voice}\u0000$chunk';
  }

  Future<_ChunkAudio?> _getAudio(String chunk, int token) {
    final key = _cacheKey(chunk);
    final cached = _cache[key];
    if (cached != null) {
      if (cached.file.existsSync()) {
        // 命中缓存：refresh LRU 顺序。
        _cache.remove(key);
        _cache[key] = cached;
        return Future.value(cached);
      }
      _cache.remove(key);
    }
    final running = _inflight[key];
    if (running != null) return running;
    final future = _synthesize(chunk, key, token);
    _inflight[key] = future;
    return future.whenComplete(() {
      if (_inflight[key] == future) _inflight.remove(key);
    });
  }

  Future<_ChunkAudio?> _synthesize(String chunk, String key, int token) async {
    final voice = paramsProvider().voice.trim();
    final apiKey = apiKeyProvider();
    final cancel = CancelToken();
    _cancels.add(cancel);
    final gen = _cacheGen;
    try {
      final bytes = await _client.synthesize(
        apiKey: apiKey,
        text: chunk,
        voice: voice.isEmpty ? 'mimo_default' : voice,
        cancelToken: cancel,
      );
      if (token != _token) return null;
      final file = await _writeTemp(bytes);
      if (gen != _cacheGen || token != _token) {
        // 换章/停止后到达的旧结果：不缓存，直接删掉。
        unawaited(_deleteFile(file));
        return null;
      }
      final audio = _ChunkAudio(file: file, duration: wavDuration(bytes));
      _store(key, audio);
      return audio;
    } on TtsException catch (e) {
      if (e.code == 'cancelled') return null;
      rethrow;
    } finally {
      _cancels.remove(cancel);
    }
  }

  Future<File> _writeTemp(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final sub = Directory('${dir.path}${Platform.pathSeparator}tts_mimo');
    if (!sub.existsSync()) await sub.create(recursive: true);
    _seq++;
    final file = File(
      '${sub.path}${Platform.pathSeparator}mimo_${_seq}_'
      '${sha1.convert(bytes.take(64).toList()).toString().substring(0, 8)}.wav',
    );
    return file.writeAsBytes(bytes, flush: true);
  }

  void _store(String key, _ChunkAudio audio) {
    final old = _cache.remove(key);
    if (old != null) _deleteIfIdle(old.file);
    _cache[key] = audio;
    while (_cache.length > _maxCacheEntries) {
      final oldestKey = _cache.keys.first;
      final removed = _cache.remove(oldestKey);
      if (removed != null) _deleteIfIdle(removed.file);
    }
  }

  void _dropFromCache(String key) {
    final audio = _cache.remove(key);
    if (audio != null) _deleteIfIdle(audio.file);
  }

  Future<void> _play(_ChunkAudio audio, int token) async {
    _currentFile = audio.file;
    _lastError = null;
    final completer = Completer<void>();
    _pending = completer;
    try {
      await _player!.open(Media(audio.file.path), play: false);
      if (token != _token) return;
      try {
        await _player!.setRate(_playbackRate);
      } catch (e) {
        debugPrint('[tts:mimo] 播放倍速设置失败：$e');
      }
      await _player!.play();
      if (token != _token) return;
      final wait = audio.duration == null
          ? const Duration(seconds: 90)
          : Duration(
              microseconds:
                  audio.duration!.inMicroseconds ~/ _playbackRate +
                  15 * 1000 * 1000,
            );
      await completer.future.timeout(wait, onTimeout: () {});
      if (token != _token) return;
      if (_lastError != null) {
        throw TtsException('playback_failed', _lastError!);
      }
    } finally {
      if (identical(_pending, completer)) _pending = null;
    }
  }

  @override
  Future<void> stop() async {
    _token++;
    for (final cancel in _cancels.toList()) {
      if (!cancel.isCancelled) cancel.cancel('tts stop');
    }
    _cancels.clear();
    _finishPending();
    try {
      await _player?.stop();
    } catch (e) {
      debugPrint('[tts:mimo] stop 失败：$e');
    }
  }

  /// 换章清理：删除旧章音频缓存并撤销在途请求（当前播放文件保留到 stop）。
  @override
  void resetCache() {
    _cacheGen++;
    for (final cancel in _cancels.toList()) {
      if (!cancel.isCancelled) cancel.cancel('chapter changed');
    }
    _cancels.clear();
    _inflight.clear();
    final files = [for (final audio in _cache.values) audio.file];
    _cache.clear();
    for (final file in files) {
      _deleteIfIdle(file);
    }
  }

  @override
  Future<void> testConnection() async {
    final bytes = await _client.synthesize(
      apiKey: apiKeyProvider(),
      text: '你好，这是 MiMo 朗读连通性测试。',
      voice: paramsProvider().voice,
      cancelToken: null,
    );
    if (bytes.isEmpty) {
      throw const TtsException('empty_audio', 'MiMo 返回空音频');
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _completedSub?.cancel();
    await _errorSub?.cancel();
    await _player?.dispose();
    _player = null;
    _cacheGen++;
    _inflight.clear();
    final files = [for (final audio in _cache.values) audio.file];
    _cache.clear();
    for (final file in files) {
      await _deleteFile(file);
    }
    final current = _currentFile;
    _currentFile = null;
    if (current != null) await _deleteFile(current);
  }

  void _deleteIfIdle(File file) {
    final current = _currentFile;
    if (current != null && current.path == file.path) return;
    unawaited(_deleteFile(file));
  }

  Future<void> _deleteFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('[tts:mimo] 删除临时音频失败：$e');
    }
  }

  static String _shortError(Object error) {
    final raw = error.toString().replaceFirst(RegExp(r'^TtsException\([^)]*\):\s*'), '');
    return raw.length <= 120 ? raw : '${raw.substring(0, 120)}…';
  }
}

class _ChunkAudio {
  const _ChunkAudio({required this.file, required this.duration});

  final File file;
  final Duration? duration;
}

/// 解析 WAV 头得到时长（MiMo 固定返回 24 kHz 单声道 PCM）。
///
/// 解析失败返回 null，此时跳过时长校验（宁可不拦，也不误杀正常音频）。
Duration? wavDuration(Uint8List bytes) {
  if (bytes.length < 16) return null;
  const riff = 0x52; // R
  if (bytes[0] != riff || bytes[1] != 0x49 || bytes[2] != 0x46 || bytes[3] != 0x46) {
    return null;
  }
  var offset = 12;
  int? byteRate;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = _le32(bytes, offset + 4);
    final dataStart = offset + 8;
    if (id == 'fmt ' && dataStart + 12 <= bytes.length) {
      byteRate = _le32(bytes, dataStart + 8);
    } else if (id == 'data') {
      if (byteRate == null || byteRate <= 0) return null;
      var dataSize = size;
      if (dataStart + dataSize > bytes.length) {
        dataSize = bytes.length - dataStart;
      }
      if (dataSize <= 0) return null;
      return Duration(microseconds: dataSize * 1000000 ~/ byteRate);
    }
    offset = dataStart + size + (size.isOdd ? 1 : 0);
    if (size < 0) return null;
  }
  return null;
}

int _le32(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);
