import 'media_bridge.dart';

/// 播放权归属：B 站收听 / 本地书 TTS / 空闲。
enum PlaybackOwner { none, bili, tts }

/// 播放互斥收敛点（docs/reader-design.md §5.3）。
///
/// - B 站播放启动前经 [claimBili]：若 TTS 在播，先停 TTS；
/// - TTS 启动前经 [claimTts]：若 B 站在播，先停 B 站；
/// - 两者共用同一个 `audio_service` 媒体会话，切换时重新绑定系统回调，
///   保证锁屏/通知栏控制始终指向**当前**发声方。
class PlaybackArbiter {
  PlaybackArbiter({required this.media});

  final MediaSessionBridge media;

  PlaybackOwner owner = PlaybackOwner.none;

  // B 站播放器注册的回调
  void Function()? _biliBind;
  void Function()? _biliBindFocus;
  Future<void> Function()? _biliStop;
  void Function()? _biliPublish;

  // TTS 会话注册的回调
  void Function()? _ttsBind;
  void Function()? _ttsBindFocus;
  Future<void> Function()? _ttsStop;

  void registerBili({
    required void Function() bind,
    required void Function() bindFocus,
    required Future<void> Function() stop,
    required void Function() publish,
  }) {
    _biliBind = bind;
    _biliBindFocus = bindFocus;
    _biliStop = stop;
    _biliPublish = publish;
  }

  void registerTts({
    required void Function() bind,
    required void Function() bindFocus,
    required Future<void> Function() stop,
  }) {
    _ttsBind = bind;
    _ttsBindFocus = bindFocus;
    _ttsStop = stop;
  }

  /// B 站播放前申请播放权。
  Future<void> claimBili() async {
    if (owner == PlaybackOwner.tts) await _ttsStop?.call();
    owner = PlaybackOwner.bili;
    _biliBindFocus?.call();
    _biliBind?.call();
    _biliPublish?.call();
  }

  /// TTS 开始前申请播放权。
  Future<void> claimTts() async {
    if (owner == PlaybackOwner.bili) await _biliStop?.call();
    owner = PlaybackOwner.tts;
    _ttsBindFocus?.call();
    _ttsBind?.call();
  }

  /// TTS 结束：把系统媒体会话与焦点交还 B 站播放器（不自动播放）。
  void releaseTts() {
    if (owner != PlaybackOwner.tts) return;
    owner = PlaybackOwner.none;
    _biliBindFocus?.call();
    _biliBind?.call();
    _biliPublish?.call();
  }

  bool get isTts => owner == PlaybackOwner.tts;
}
