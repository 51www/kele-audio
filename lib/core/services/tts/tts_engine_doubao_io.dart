import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'doubao_tts_client.dart';
import 'tts_engine.dart';

/// 豆包 TTS 引擎（实验性）：WebSocket 合成 WAV → 独立 media_kit Player 播放。
///
/// 与 Edge 引擎同构：支持前瞻预合成以缩短段间停顿，但豆包网页端有风控，
/// 客户端侧已做最小请求间隔限流；仍不宜高频/长时间连续调用。
class TtsDoubaoEngine implements TtsEngine, BatchingTtsEngine {
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

  // 豆包风控敏感：多句合并降低请求数，预取收窄到 1 避免瞬间连发。
  @override
  int get maxSentencesPerSegment => 5;

  @override
  int get prefetchDepth => 1;

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
        return _padTailSilence(bytes);
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

  /// 批量段之间的听感喘息。
  ///
  /// 音频内部的句间停顿由 TTS 模型自然生成，但两次合成请求的音频衔接处
  /// 是硬接的（上一段播完立即 open 下一段），听感过于紧凑。在每段 WAV
  /// 末尾追加 PCM 静音，把停顿做进音频流里，衔接自然且暂停/停止天然同步。
  static const Duration _segmentTailPause = Duration(milliseconds: 420);

  /// 在 WAV 的 data chunk 尾部追加 [_segmentTailPause] 的静音。
  ///
  /// 豆包输出的是流式 WAV：RIFF/data 的 size 字段均为 0xFFFFFFFF 占位，
  /// 真实长度只到文件尾。因此以「到 EOF 的实际长度」为准，追加后把两个
  /// size 字段一并修正为真实值（顺带把流式 WAV 修成标准 WAV）。
  /// 结构不符合预期（非 RIFF / 找不到 data）时原样返回，不影响播放。
  Uint8List _padTailSilence(Uint8List wav) {
    if (wav.length < 44) return wav;
    if (String.fromCharCodes(wav.sublist(0, 4)) != 'RIFF') return wav;
    // 从 fmt chunk 读取采样参数，兜底豆包固定输出（24kHz / 16bit / mono）。
    var rate = 24000, channels = 1, bits = 16;
    var offset = 12; // 跳过 "RIFF" + size + "WAVE"
    int? dataOffset;
    while (offset + 8 <= wav.length) {
      final id = String.fromCharCodes(wav.sublist(offset, offset + 4));
      final size = ByteData.sublistView(wav, offset + 4, offset + 8)
          .getUint32(0, Endian.little);
      if (id == 'data') {
        dataOffset = offset;
        break;
      }
      if (id == 'fmt ' && offset + 24 <= wav.length) {
        final fmt = ByteData.sublistView(wav, offset + 8, offset + 24);
        channels = fmt.getUint16(2, Endian.little);
        rate = fmt.getUint32(4, Endian.little);
        bits = fmt.getUint16(14, Endian.little);
      }
      // size 字段无效（流式占位 0xFFFFFFFF）时无法跳到下一个 chunk。
      if (size == 0xFFFFFFFF) break;
      offset += 8 + size + (size.isOdd ? 1 : 0);
    }
    if (dataOffset == null) return wav;
    final dataStart = dataOffset + 8;
    final actualDataLen = wav.length - dataStart;
    final bytesPerFrame = channels * (bits ~/ 8);
    if (rate <= 0 || bytesPerFrame <= 0 || actualDataLen <= 0) return wav;
    // 静音长度按采样帧对齐，避免 data 尺寸非帧整数倍。
    final silenceLen = ((rate * bytesPerFrame * _segmentTailPause.inMilliseconds) ~/
            1000 ~/
            bytesPerFrame) *
        bytesPerFrame;
    final padded = Uint8List(wav.length + silenceLen)
      ..setRange(0, wav.length, wav);
    final bd = ByteData.sublistView(padded);
    // data chunk size 与 RIFF 总 size（文件长 - 8）都修正为真实值。
    bd.setUint32(dataOffset + 4, actualDataLen + silenceLen, Endian.little);
    bd.setUint32(4, padded.length - 8, Endian.little);
    return padded;
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
        '${DateTime.now().microsecondsSinceEpoch}.wav',
      );
      await file.writeAsBytes(bytes, flush: true);
      writtenFile = file;
      _currentFile = file;
      await _player!.open(Media(file.path), play: true);
      if (token != _token) return;
      // open() 返回后 mpv 的状态异步刷新：连续朗读时上一段刚播完，
      // state.completed 可能仍残留 true。此刻立即读取会把本段误判为
      // 「已播完」，speak 提前返回导致下一段抢读。等新播放会话真正
      // 开始（playing 且非 completed）后再启用完成检测。
      final startedAt = DateTime.now();
      while (DateTime.now().difference(startedAt) < const Duration(seconds: 3)) {
        final st = _player!.state;
        if (st.playing && !st.completed) break;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
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
