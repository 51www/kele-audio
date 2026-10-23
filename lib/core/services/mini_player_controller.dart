import 'package:flutter/foundation.dart';

/// MiniPlayer（全局播放条）状态。
///
/// M1 只做占位：`hasTask == false`，UI 展示空闲态；
/// M2 接入 `core/services/player` 后，由播放器回调驱动 [update]。
class MiniPlayerController extends ChangeNotifier {
  MiniPlayerState _state = MiniPlayerState.idle();

  MiniPlayerState get state => _state;

  /// M1 阶段占位常驻（便于验收 UI 结构）；M2 起改为 `hasTask` 才显示。
  bool get placeholderVisible => !_state.hasTask;

  void update(MiniPlayerState next) {
    if (next == _state) return;
    _state = next;
    notifyListeners();
  }

  void reset() => update(MiniPlayerState.idle());
}

@immutable
class MiniPlayerState {
  const MiniPlayerState({
    this.hasTask = false,
    this.albumTitle = '',
    this.chapterTitle = '',
    this.coverUrl = '',
    this.progress = 0,
    this.playing = false,
  });

  const MiniPlayerState.idle() : this();

  final bool hasTask;
  final String albumTitle;
  final String chapterTitle;
  final String coverUrl;

  /// 0~1
  final double progress;
  final bool playing;

  @override
  bool operator ==(Object other) =>
      other is MiniPlayerState &&
      other.hasTask == hasTask &&
      other.albumTitle == albumTitle &&
      other.chapterTitle == chapterTitle &&
      other.coverUrl == coverUrl &&
      other.progress == progress &&
      other.playing == playing;

  @override
  int get hashCode => Object.hash(
        hasTask,
        albumTitle,
        chapterTitle,
        coverUrl,
        progress,
        playing,
      );
}
