import 'dart:async';

import 'package:audio_service/audio_service.dart';

import 'media_bridge.dart';

/// 基于 audio_service 的系统媒体中心接入（P-01 后台 / P-02 锁屏通知 / P-06 线控）。
///
/// 只在移动端启用（`main.dart` 按 `kIsWeb` 判断）。它实现 [MediaSessionBridge]：
/// - 系统 → 播放器：通知栏/锁屏/蓝牙/线控的 play/pause/seek/上一首/下一首
///   全部汇到 `bind()` 注册的回调（即 `PlayerService`）；
/// - 播放器 → 系统：`publish()` 把 [MediaSnapshot] 推成 audio_service 的
///   `MediaItem` + `PlaybackState`（通知栏文案、进度、可点按钮）。
///
/// 初始化失败时 `main.dart` 会降级为 [NoopMediaBridge]，播放照常。
class AudioServiceBridge extends BaseAudioHandler implements MediaSessionBridge {
  // 系统 → 播放器 的回调（由 PlayerService.bind 注入）
  Future<void> Function()? _onPlay;
  Future<void> Function()? _onPause;
  Future<void> Function(Duration)? _onSeek;
  Future<void> Function()? _onNext;
  Future<void> Function()? _onPrev;
  Future<void> Function()? _onStop;
  Future<void> Function()? _onFastForward;
  Future<void> Function()? _onRewind;

  @override
  void bind({
    required Future<void> Function() onPlay,
    required Future<void> Function() onPause,
    required Future<void> Function(Duration) onSeek,
    required Future<void> Function() onNext,
    required Future<void> Function() onPrev,
    required Future<void> Function() onStop,
    Future<void> Function()? onFastForward,
    Future<void> Function()? onRewind,
  }) {
    _onPlay = onPlay;
    _onPause = onPause;
    _onSeek = onSeek;
    _onNext = onNext;
    _onPrev = onPrev;
    _onStop = onStop;
    _onFastForward = onFastForward;
    _onRewind = onRewind;
  }

  @override
  void publish(MediaSnapshot s) {
    if (!s.active) {
      // 无播放任务：先清媒体项再收掉通知栏
      mediaItem.add(null);
      playbackState.add(PlaybackState(
        processingState: AudioProcessingState.idle,
        playing: false,
      ));
      return;
    }
    mediaItem.add(MediaItem(
      id: s.chapterTitle,
      title: s.chapterTitle.isEmpty ? s.albumTitle : s.chapterTitle,
      artist: s.albumTitle,
      album: s.albumTitle,
      artUri: s.coverUrl.isEmpty ? null : Uri.tryParse(s.coverUrl),
      duration: s.duration > Duration.zero ? s.duration : null,
    ));

    // 控件顺序随「上一章/下一章可用性」变化，所以紧凑栏下标必须跟着算：
    // PlaybackState 断言 androidCompactActionIndices.length <= 3，
    // 写死 4 个会让整条 playbackState 推送抛断言 → 通知栏/锁屏永远是空的（P-02）。
    final controls = <MediaControl>[
      if (s.hasPrev) MediaControl.skipToPrevious,
      if (s.playing) MediaControl.pause else MediaControl.play,
      if (s.hasNext) MediaControl.skipToNext,
      // 停止放最后、不进紧凑栏（Android 13+ 会把它变成需要图标的自定义动作）
      MediaControl.stop,
    ];

    playbackState.add(playbackState.value.copyWith(
      playing: s.playing,
      processingState: AudioProcessingState.ready,
      updatePosition: s.position,
      speed: s.speed,
      controls: controls,
      androidCompactActionIndices: List.generate(
        controls.length - 1,
        (i) => i,
      ),
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
    ));
  }

  // ---------------------------------------------------------------- 系统回调
  @override
  Future<void> play() async => _onPlay?.call();

  @override
  Future<void> pause() async => _onPause?.call();

  @override
  Future<void> stop() async => _onStop?.call();

  @override
  Future<void> seek(Duration position) async => _onSeek?.call(position);

  @override
  Future<void> skipToNext() async => _onNext?.call();

  @override
  Future<void> skipToPrevious() async => _onPrev?.call();

  @override
  Future<void> fastForward() async => _onFastForward?.call();

  @override
  Future<void> rewind() async => _onRewind?.call();

  @override
  Future<void> shutdown() async {
    playbackState.add(PlaybackState(
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
  }
}
