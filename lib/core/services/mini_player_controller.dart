import 'package:flutter/foundation.dart';

/// MiniPlayer（全局播放条）状态。
///
/// 由 `core/services/player` 的 [PlayerService] 回调驱动 [update]。
/// 显示规则（需求）：
/// - 无播放内容（[MiniPlayerState.hasTask] == false）不显示播放条；
/// - 有播放任务时常驻，用户点 ✕ 关闭后收起（[close]）；
/// - 开始新的播放任务（装载章节）时自动重新显示（[reopen]）。
class MiniPlayerController extends ChangeNotifier {
  MiniPlayerState _state = MiniPlayerState.idle();
  bool _closed = false;

  MiniPlayerState get state => _state;

  /// 是否被用户手动关闭（与「无播放内容」是两种独立的隐藏原因）。
  bool get closed => _closed;

  /// 播放条是否可见：有播放任务 且 未被手动关闭。
  bool get visible => _state.hasTask && !_closed;

  void update(MiniPlayerState next) {
    if (next == _state) return;
    _state = next;
    notifyListeners();
  }

  /// 关闭播放条（仅收起 UI；是否暂停由调用方决定）。
  void close() {
    if (_closed) return;
    _closed = true;
    notifyListeners();
  }

  /// 重新显示播放条（清除关闭标记）——开始新播放任务时调用。
  void reopen() {
    if (!_closed) return;
    _closed = false;
    notifyListeners();
  }

  /// 回到空闲态并清除关闭标记（测试 / 重置用）。
  void reset() {
    _closed = false;
    update(MiniPlayerState.idle());
  }
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
