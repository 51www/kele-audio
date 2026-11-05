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

  // 上一次真正推给系统的快照（字段级 diff 用）。
  // PlayerService 播放中每 500ms publish 一次，若每次都 mediaItem.add /
  // playbackState.add，通知栏会被高频重建——部分机型每重建一次就「叮」
  // 一声，直接盖过听书声音。只在状态真变化时才推。
  MediaItem? _lastItem;
  bool? _lastPlaying;
  double? _lastSpeed;
  String? _lastControlKeys;
  Duration? _lastPosition;
  DateTime? _lastPushedAt;

  void _resetSnapshot() {
    _lastItem = null;
    _lastPlaying = null;
    _lastSpeed = null;
    _lastControlKeys = null;
    _lastPosition = null;
    _lastPushedAt = null;
  }

  static bool _sameItem(MediaItem? a, MediaItem? b) {
    if (a == null || b == null) return a == null && b == null;
    return a.id == b.id &&
        a.title == b.title &&
        a.artist == b.artist &&
        a.album == b.album &&
        a.artUri == b.artUri &&
        a.duration == b.duration;
  }

  /// 当前进度与上一次推送相比，是否只是「正常走表」。
  ///
  /// `PlaybackState` 携带 `updatePosition + updateTime + speed`，系统会自己
  /// 按时间外推锁屏/通知栏进度条，所以只要新位置落在外推值附近就无需重推。
  bool _positionOnTrack(MediaSnapshot s) {
    final anchor = _lastPosition;
    final pushedAt = _lastPushedAt;
    if (anchor == null || pushedAt == null) return false;
    Duration expected;
    if (s.playing) {
      final speed = (_lastSpeed ?? 1.0).clamp(0.25, 4.0).toDouble();
      final elapsed = DateTime.now().difference(pushedAt).inMilliseconds;
      expected = anchor + Duration(milliseconds: (elapsed * speed).round());
    } else {
      expected = anchor;
    }
    return (s.position - expected).abs() <= const Duration(seconds: 3);
  }

  @override
  void publish(MediaSnapshot s) {
    if (!s.active) {
      // 已经是 idle 就别重复推（重复收通知也会触发一次提示音）。
      if (_lastPlaying == null && _lastItem == null) return;
      _resetSnapshot();
      // 无播放任务：先清媒体项再收掉通知栏
      mediaItem.add(null);
      playbackState.add(PlaybackState(
        processingState: AudioProcessingState.idle,
        playing: false,
      ));
      return;
    }

    final item = MediaItem(
      id: s.chapterTitle,
      title: s.chapterTitle.isEmpty ? s.albumTitle : s.chapterTitle,
      artist: s.albumTitle,
      album: s.albumTitle,
      artUri: s.coverUrl.isEmpty ? null : Uri.tryParse(s.coverUrl),
      duration: s.duration > Duration.zero ? s.duration : null,
    );
    // 文案/封面没变就不重推 mediaItem，避免通知栏行内容反复刷新。
    if (!_sameItem(_lastItem, item)) {
      _lastItem = item;
      mediaItem.add(item);
    }

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
    final controlKeys = controls.map((c) => c.action.name).join(',');

    // 播放状态、控件、倍速都没变，且进度只是走表 → 整条 playbackState
    // 跳过推送：系统按上一次的 updatePosition + speed 自行外推进度。
    if (_lastPlaying == s.playing &&
        _lastSpeed == s.speed &&
        _lastControlKeys == controlKeys &&
        _positionOnTrack(s)) {
      return;
    }

    _lastPlaying = s.playing;
    _lastSpeed = s.speed;
    _lastControlKeys = controlKeys;
    _lastPosition = s.position;
    _lastPushedAt = DateTime.now();

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
    _resetSnapshot();
    playbackState.add(PlaybackState(
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
  }
}
