/// 系统媒体会话桥（锁屏 / 通知栏 / 蓝牙线控）的**抽象层**。
///
/// 为什么抽这一层：
/// - `player_service.dart` 只认 [MediaSessionBridge]，不 import `audio_service`，
///   于是播放核心保持纯 Dart（单测可跑，Web 编译不受插件影响）；
/// - 真正的实现 `audio_service_bridge.dart` 在 app 装配阶段注入，
///   初始化失败时退化成 [NoopMediaBridge]，**播放照常**（降级不阻塞）。
///
/// 对应 PRD：P-01 后台播放、P-02 锁屏/通知栏控制、P-06 线控/蓝牙按键。
library;

/// 推给系统媒体会话的状态快照。
class MediaSnapshot {
  const MediaSnapshot({
    this.active = false,
    this.playing = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.albumTitle = '',
    this.chapterTitle = '',
    this.coverUrl = '',
    this.hasNext = false,
    this.hasPrev = false,
  });

  /// 无播放任务时为 false（此时应把通知收掉）
  final bool active;
  final bool playing;
  final Duration position;
  final Duration duration;
  final String albumTitle;
  final String chapterTitle;
  final String coverUrl;
  final bool hasNext;
  final bool hasPrev;

  MediaSnapshot copyWith({
    bool? active,
    bool? playing,
    Duration? position,
    Duration? duration,
    String? albumTitle,
    String? chapterTitle,
    String? coverUrl,
    bool? hasNext,
    bool? hasPrev,
  }) =>
      MediaSnapshot(
        active: active ?? this.active,
        playing: playing ?? this.playing,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        albumTitle: albumTitle ?? this.albumTitle,
        chapterTitle: chapterTitle ?? this.chapterTitle,
        coverUrl: coverUrl ?? this.coverUrl,
        hasNext: hasNext ?? this.hasNext,
        hasPrev: hasPrev ?? this.hasPrev,
      );
}

abstract class MediaSessionBridge {
  /// 注册**系统 → 播放器**的控制回调（通知栏/锁屏/线控/蓝牙按键都会汇到这里）
  void bind({
    required Future<void> Function() onPlay,
    required Future<void> Function() onPause,
    required Future<void> Function(Duration) onSeek,
    required Future<void> Function() onNext,
    required Future<void> Function() onPrev,
    required Future<void> Function() onStop,
    Future<void> Function()? onFastForward,
    Future<void> Function()? onRewind,
  });

  /// **播放器 → 系统**：推送状态（由调用方节流）
  void publish(MediaSnapshot snapshot);

  Future<void> shutdown();
}

/// 桥接不可用时的空实现：所有调用安全为空。
class NoopMediaBridge implements MediaSessionBridge {
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
  }) {}

  @override
  void publish(MediaSnapshot snapshot) {}

  @override
  Future<void> shutdown() async {}
}
