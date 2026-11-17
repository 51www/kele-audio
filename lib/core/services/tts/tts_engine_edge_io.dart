import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'edge_tts_client.dart';
import 'tts_engine.dart';

/// Edge TTS 引擎：WebSocket 合成 MP3 → 独立 media_kit Player 播放。
///
/// 预合成队列支持会话向前预取数句：播放第 i 段时提前合成后续片段，
/// 段间停顿只受本地文件切换影响。
class TtsEdgeEngine implements TtsEngine {
  TtsEdgeEngine();

  Player? _player;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<String>? _errorSub;
  Completer<void>? _pending;

  /// 完成事件只有在当前段的 Media 已经 open 之后才有效。
  /// 否则上一句迟到的 completed 会提前 complete 本句的 _pending，
  /// 表现为「前一句还没念完，下一句就开始了」。
  bool _completionArmed = false;
  String? _lastError;
  TtsParams _params = const TtsParams();

  /// stop 时自增，用于让进行中的合成/播放尽快退出。
  int _token = 0;
  int _seq = 0;

  /// 预合成结果（text → 音频字节）；合成失败不保留，正式朗读时会重试。
  final Map<String, Uint8List> _prefetched = {};
  final Set<String> _prefetching = {};

  /// 预合成代际：切参数 / 切章 / 停止后自增，让在途请求的结果作废，
  /// 避免用旧音色、旧语速合成的音频被后续 speak 命中。
  int _cacheGeneration = 0;

  File? _currentFile;

  @override
  String get id => 'edge';

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

  EdgeTtsClient _client() {
    final ratePercent = ((_params.rate - 1.0) * 100).round();
    final pitchHz = ((_params.pitch - 1.0) * 50).round();
    return EdgeTtsClient(
      voice: _params.voice.isEmpty ? 'zh-CN-XiaoxiaoNeural' : _params.voice,
      rate: '${ratePercent >= 0 ? '+' : ''}$ratePercent%',
      pitch: '${pitchHz >= 0 ? '+' : ''}$pitchHz' 'Hz',
    );
  }

  @override
  Future<void> start(TtsParams params) async {
    // 播放页切换音色 / 语速也会走到这里：旧参数的预合成音频必须先作废。
    _invalidatePrefetch();
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

  /// 合成失败自动重试 2 次（网络抖动是 Edge 最常见的失败原因）。
  Future<Uint8List> _synthesize(String text) async {
    Object? last;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final bytes = await _client()
            .synthesize(text)
            .timeout(const Duration(seconds: 25));
        if (bytes.isEmpty) {
          throw const TtsException('empty_audio', 'Edge 未返回音频数据');
        }
        return bytes;
      } catch (e) {
        last = e;
        if (attempt == 2) break;
        await Future<void>.delayed(Duration(milliseconds: 800 * (attempt + 1)));
      }
    }
    throw TtsException('edge_failed', _cleanError(last ?? 'Edge 合成失败'));
  }

  @override
  void prefetch(String text) {
    if (text.trim().isEmpty) return;
    if (_prefetched.containsKey(text) || _prefetching.contains(text)) return;
    final generation = _cacheGeneration;
    _prefetching.add(text);
    unawaited(
      _synthesize(text)
          .then((bytes) {
            // 参数或会话已变，在途结果直接丢弃。
            if (generation != _cacheGeneration) return;
            _prefetched[text] = bytes;
            // 覆盖会话的前瞻预取窗口（当前句 + 后续数句），避免刚合成的下一段
            // 被更早的缓存挤出，导致播到那里又现场合成、出现长停顿。
            while (_prefetched.length > 6) {
              _prefetched.remove(_prefetched.keys.first);
            }
          })
          .catchError((Object e) {
            debugPrint('[tts:edge] 预合成失败（朗读时重试）：$e');
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
    // 合成/写文件期间关闭闸门：上一句迟到的 completed 不能提前结束本句。
    _completionArmed = false;
    _pending = completer;
    try {
      final cached = _prefetched.remove(text);
      final bytes = cached ??
          await _synthesize(text).timeout(const Duration(seconds: 90));
      if (token != _token) return;

      final dir = await getTemporaryDirectory();
      _seq++;
      final file = File(
        '${dir.path}${Platform.pathSeparator}tts_${_seq}_'
        '${DateTime.now().microsecondsSinceEpoch}.mp3',
      );
      await file.writeAsBytes(bytes, flush: true);
      _currentFile = file;
      await _player!.open(Media(file.path), play: true);
      if (token != _token) return;
      // 只有到这里才允许 completed 结束等待；极短音频可能在 open 期间就播完，
      // 补一次状态检查，避免一直等到超时。
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
      throw const TtsException('network_timeout', 'Edge 合成超时');
    } catch (e) {
      throw TtsException('edge_failed', _cleanError(e));
    } finally {
      if (identical(_pending, completer)) {
        _pending = null;
        _completionArmed = false;
      }
      await _cleanupCurrentFile();
    }
  }

  Future<void> _cleanupCurrentFile() async {
    final file = _currentFile;
    _currentFile = null;
    if (file == null) return;
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
      debugPrint('[tts:edge] stop 失败：$e');
    }
    await _cleanupCurrentFile();
  }

  /// 换章清理预合成队列，避免旧章文本占用内存或旧音频被误用。
  @override
  void resetCache() => _invalidatePrefetch();

  @override
  Future<void> testConnection() async {
    final bytes = await _synthesize('你好，这是朗读连通性测试。');
    if (bytes.isEmpty) {
      throw const TtsException('empty_audio', 'Edge 未返回音频数据');
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
