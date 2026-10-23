import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'player_engine.dart';

/// 播放内核实现：`media_kit`（AGENT.md 技术决策，**不引 just_audio**）。
///
/// 一份代码跑两个平台，差异只有两点：
/// 1. **取流请求头**：原生端 `Media(url, httpHeaders: {UA, Referer})`
///    由 libmpv 直接带上（B 站 CDN 缺一即 403）；Web 站浏览器禁止设置
///    这些「禁止头」，改走 `tool/dev_proxy.mjs` 的 `/audio` 反代补全，
///    见 [_viaProxy]。
/// 2. `MediaKit.ensureInitialized()`：原生端装载 libmpv，Web 端是空实现。
///
/// 关键坑（abts 实测）：**每次 `open()` 换源后 media_kit 的速率会复位**，
/// 必须在打开后显式恢复，否则倍速在切章/重连后被偷偷打回 1.0。
class MediaKitEngine implements PlayerEngine {
  MediaKitEngine() {
    MediaKit.ensureInitialized();
    _player = Player();
    _positionSub = _player.stream.position.listen(_position.add);
    _durationSub = _player.stream.duration.listen(_duration.add);
    _playingSub = _player.stream.playing.listen(_playing.add);
    _bufferingSub = _player.stream.buffering.listen(_buffering.add);
    _completedSub = _player.stream.completed.listen((done) {
      if (done) _completed.add(null);
    });
    _errorSub = _player.stream.error.listen((e) {
      if (e.isNotEmpty) _errors.add(e);
    });
  }

  late final Player _player;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _errors = StreamController<String>.broadcast();

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<String>? _errorSub;

  /// 当前速率（换源后回填，见类注释）
  double _rate = 1.0;
  double _volume = 1.0;
  bool _disposed = false;

  @override
  Stream<Duration> get position => _position.stream;

  @override
  Stream<Duration> get duration => _duration.stream;

  @override
  Stream<bool> get playing => _playing.stream;

  @override
  Stream<bool> get buffering => _buffering.stream;

  @override
  Stream<void> get completed => _completed.stream;

  @override
  Stream<String> get errors => _errors.stream;

  @override
  Duration get positionValue => _player.state.position;

  @override
  Duration get durationValue => _player.state.duration;

  @override
  bool get isPlaying => _player.state.playing;

  @override
  double get rate => _rate;

  @override
  double get volume => _volume;

  @override
  Future<void> open({
    required String url,
    Map<String, String>? headers,
    bool autoplay = true,
    Duration startAt = Duration.zero,
  }) async {
    final target = kIsWeb ? _viaProxy(url, headers) : url;
    final media = Media(target, httpHeaders: kIsWeb ? null : headers);

    await _player.open(media, play: autoplay);

    // 换源后恢复倍速 / 音量（media_kit 会复位）
    if (_rate != 1.0) await _player.setRate(_rate);
    if (_volume != 1.0) await _player.setVolume(_volume);

    if (startAt > Duration.zero) {
      await _seekTo(startAt, autoplay: autoplay);
    }
  }

  /// 精确跳转：等时长解析出来再 seek，落点偏差大时再补一次
  /// （刚 open 时 media_kit 的 duration 可能还是 0，首跳会被忽略）。
  Future<void> _seekTo(Duration to, {required bool autoplay}) async {
    if (durationValue <= Duration.zero) {
      try {
        await _player.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 4));
      } catch (_) {
        // 超时继续，靠下面的落点校验兜底
      }
    }
    await _player.seek(to);
    if (autoplay) await _player.play();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final off = (_player.state.position - to).inMilliseconds.abs();
    if (off > 5000 && !_disposed) {
      await _player.seek(to);
    }
  }

  /// Web 站：把音源改写成本地反代地址，由反代补 UA/Referer（CORS 限制）。
  ///
  /// 仅在**预览环境**（`tool/dev_proxy.mjs`）下有效；Android 端直连 CDN。
  static String _viaProxy(String url, Map<String, String>? headers) {
    final buf = StringBuffer('/audio?u=${Uri.encodeComponent(url)}');
    final ref = headers?['Referer'];
    if (ref != null && ref.isNotEmpty) {
      buf.write('&ref=${Uri.encodeComponent(ref)}');
    }
    final ua = headers?['User-Agent'];
    if (ua != null && ua.isNotEmpty) {
      buf.write('&ua=${Uri.encodeComponent(ua)}');
    }
    return buf.toString();
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration to) => _player.seek(to);

  @override
  Future<void> setRate(double v) async {
    _rate = v.clamp(0.5, 3.0);
    await _player.setRate(_rate);
  }

  @override
  Future<void> setVolume(double v) async {
    _volume = v.clamp(0.0, 1.0);
    await _player.setVolume(_volume);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _positionSub?.cancel();
    await _durationSub?.cancel();
    await _playingSub?.cancel();
    await _bufferingSub?.cancel();
    await _completedSub?.cancel();
    await _errorSub?.cancel();
    await _player.dispose();
    await _position.close();
    await _duration.close();
    await _playing.close();
    await _buffering.close();
    await _completed.close();
    await _errors.close();
  }
}

/// 生产入口：App 侧只依赖 [PlayerEngine]。
PlayerEngine createPlayerEngine() => MediaKitEngine();
