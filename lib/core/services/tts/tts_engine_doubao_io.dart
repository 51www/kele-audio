import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'doubao_tts_client.dart';
import 'tts_engine.dart';

/// 豆包 TTS 引擎（实验性）：WebSocket 合成 AAC → 独立 media_kit Player 播放。
///
/// 与 Edge 引擎同构：支持前瞻预合成以缩短段间停顿，但豆包网页端有风控，
/// 客户端侧已做最小请求间隔限流；仍不宜高频/长时间连续调用。
class TtsDoubaoEngine implements TtsEngine {
  TtsDoubaoEngine({required this.cookieProvider});

  /// 登录态 Cookie 提供者。每次合成都读取最新值，用户在设置页粘贴新 Cookie
  /// 后立即生效，无需切换引擎或重启。
  final String Function() cookieProvider;

  Player? _player;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<String>? _errorSub;
  Completer<void>? _pending;
  bool _completionArmed = false;
  String? _lastError;
  TtsParams _params = const TtsParams();

  int _token = 0;
  int _seq = 0;

  final Map<String, Uint8List> _prefetched = {};
  final Map<String, Future<Uint8List>> _prefetching = {};
  int _cacheGeneration = 0;
  bool _started = false;

  File? _currentFile;

  @override
  String get id => 'doubao';

  void _ensurePlayer() {
    if (_player != null) return;
    MediaKit.ensureInitialized();
    final player = Player();
    _player = player;
    _completedSub = player.stream.completed.listen((done) {
      if (!done || !_completionArmed) return;
      _completionArmed = false;
      _pending?.complete();
    });
    _errorSub = player.stream.error.listen((message) {
      if (message.isEmpty || !_completionArmed) return;
      _lastError = message;
      _completionArmed = false;
      _pending?.complete();
    });
  }

  DoubaoTtsClient _client() {
    // 应用语速 0.5~3.0 / 音调 0.5~2.0 映射到豆包的 -100~100 区间。
    final rate = ((_params.rate - 1.0) * 100).round().clamp(-100, 100);
    final pitch = ((_params.pitch - 1.0) * 100).round().clamp(-100, 100);
    return DoubaoTtsClient(
      cookie: cookieProvider(),
      speaker: _params.voice.isEmpty
          ? doubaoDefaultVoiceId
          : _params.voice,
      rate: rate,
      pitch: pitch,
    );
  }

  @override
  Future<void> start(TtsParams params) async {
    final unchanged = _started &&
        _params.voice == params.voice &&
        _params.rate == params.rate &&
        _params.pitch == params.pitch;
    if (!unchanged) _invalidatePrefetch();
    _started = true;
    _params = params;
    _ensurePlayer();
    await _player!.setRate(1.0);
  }

  void _invalidatePrefetch() {
    _cacheGeneration++;
    _prefetched.clear();
    _prefetching.clear();
  }

  static String _cleanError(Object error) {
    final raw = error.toString();
    return raw.replaceFirst(RegExp(r'^\w+Exception\([^)]*\):\s*'), '');
  }

  Future<Uint8List> _synthesize(String text) async {
    Object? last;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final bytes = await _client()
            .synthesize(text)
            .timeout(const Duration(seconds: 95));
        if (bytes.isEmpty) {
          throw const TtsException('empty_audio', '豆包未返回音频数据');
        }
        return bytes;
      } on TtsException {
        rethrow; // auth / empty_audio 等无需重试
      } on DoubaoTtsException catch (e) {
        // 风控（rate_limited）等是明确拒绝，重试只会加剧拦截——直接透传友好提示。
        throw TtsException(e.code, _cleanError(e));
      } catch (e) {
        last = e;
        if (attempt == 1) break;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    throw TtsException('doubao_failed', _cleanError(last ?? '豆包合成失败'));
  }

  @override
  void prefetch(String text) {
    if (text.trim().isEmpty) return;
    if (_prefetched.containsKey(text) || _prefetching.containsKey(text)) return;
    final generation = _cacheGeneration;
    final future = _synthesize(text);
    _prefetching[text] = future;
    unawaited(
      future
          .then((bytes) {
            if (generation != _cacheGeneration) return;
            _prefetched[text] = bytes;
            // 豆包风控敏感，预取窗口比 Edge 更小。
            while (_prefetched.length > 2) {
              _prefetched.remove(_prefetched.keys.first);
            }
          })
          .catchError((Object e) {
            debugPrint('[tts:doubao] 预合成失败（朗读时重试）：$e');
          })
          .whenComplete(() => _prefetching.remove(text)),
    );
  }

  @override
  Future<void> speak(String text) async {
    _ensurePlayer();
    final token = _token;
    _lastError = null;
    final completer = Completer<void>();
    _completionArmed = false;
    _pending = completer;
    File? writtenFile;
    try {
      final cached = _prefetched.remove(text);
      final inFlight = _prefetching.remove(text);
      Uint8List? bytes = cached;
      if (bytes == null && inFlight != null) {
        try {
          bytes = await inFlight.timeout(const Duration(seconds: 95));
        } catch (_) {
          bytes = null;
        }
      }
      bytes ??= await _synthesize(text).timeout(const Duration(seconds: 95));
      if (token != _token) return;

      final dir = await getTemporaryDirectory();
      _seq++;
      final file = File(
        '${dir.path}${Platform.pathSeparator}tts_doubao_${_seq}_'
        '${DateTime.now().microsecondsSinceEpoch}.aac',
      );
      await file.writeAsBytes(bytes, flush: true);
      writtenFile = file;
      _currentFile = file;
      await _player!.open(Media(file.path), play: true);
      if (token != _token) return;
      _completionArmed = true;
      if (_player!.state.completed) {
        _completionArmed = false;
        completer.complete();
      }
      await completer.future.timeout(
        const Duration(seconds: 300),
        onTimeout: () {},
      );
      if (_lastError != null) {
        throw TtsException('playback_failed', _lastError!);
      }
    } on TtsException {
      rethrow;
    } on TimeoutException {
      throw const TtsException('network_timeout', '豆包合成超时');
    } catch (e) {
      throw TtsException('doubao_failed', _cleanError(e));
    } finally {
      if (identical(_pending, completer)) {
        _pending = null;
        _completionArmed = false;
      }
      if (writtenFile != null) {
        if (identical(_currentFile, writtenFile)) _currentFile = null;
        await _deleteFile(writtenFile);
      }
    }
  }

  Future<void> _deleteFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    _token++;
    _completionArmed = false;
    _pending?.complete();
    _pending = null;
    _invalidatePrefetch();
    try {
      await _player?.stop();
    } catch (e) {
      debugPrint('[tts:doubao] stop 失败：$e');
    }
    final file = _currentFile;
    _currentFile = null;
    if (file != null) await _deleteFile(file);
  }

  @override
  void resetCache() => _invalidatePrefetch();

  @override
  Future<void> testConnection() async {
    final bytes = await _synthesize('你好，这是豆包朗读连通性测试。');
    if (bytes.isEmpty) {
      throw const TtsException('empty_audio', '豆包未返回音频数据');
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _completedSub?.cancel();
    await _errorSub?.cancel();
    await _player?.dispose();
    _player = null;
  }
}
