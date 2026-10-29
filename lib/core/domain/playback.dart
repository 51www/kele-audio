/// 播放核心（M2）的领域类型：播放模式、音质、播放会话。
///
/// 这里只放纯数据与枚举，不依赖 Flutter，方便 `dart run` / 单测直接复用。
library;

import 'album.dart';

/// 播放模式（PRD §5.4 控制区）：顺序 / 列表循环 / 单曲循环。
enum PlayMode {
  /// 顺序播放：播完最后一章即停
  sequential,

  /// 列表循环：最后一章结束后回到第一章
  loopAll,

  /// 单曲循环：当前章反复播放
  loopOne,
}

extension PlayModeX on PlayMode {
  String get label => switch (this) {
        PlayMode.sequential => '顺序播放',
        PlayMode.loopAll => '列表循环',
        PlayMode.loopOne => '单曲循环',
      };

  /// 图标语义名（UI 侧据此挑图标，保持 domain 无 Flutter 依赖）
  String get icon => switch (this) {
        PlayMode.sequential => 'sequential',
        PlayMode.loopAll => 'repeat',
        PlayMode.loopOne => 'repeat_one',
      };

  String get wire => switch (this) {
        PlayMode.sequential => 'sequential',
        PlayMode.loopAll => 'loop_all',
        PlayMode.loopOne => 'loop_one',
      };

  static PlayMode fromWire(String? v) => switch (v) {
        'loop_all' => PlayMode.loopAll,
        'loop_one' => PlayMode.loopOne,
        _ => PlayMode.sequential,
      };
}

/// 音质档位（PRD §5.4 / R7）：对应 B 站 DASH 音轨 id。
///
/// 30216 = 64K AAC（省流）、30232 = 132K（默认）、30280 = 192K、
/// 30251 = Hi-Res FLAC（无损，需大会员）。
/// 注意：**选档是客户端在 `dash.audio` 里挑音轨**，不改变 playurl 请求参数；
/// Hi-Res 走独立的 `dash.flac` 字段。
///
/// 解锁梯度：64K/132K 匿名可用 → 192K **绑定解锁** → Hi-Res **大会员解锁**。
/// 杜比（30250）不立档位，仅作 AAC 全挂时的兜底。
enum AudioQuality {
  q64k(trackId: 30216),
  q132k(trackId: 30232),
  q192k(trackId: 30280),
  qHiRes(trackId: 30251);

  const AudioQuality({required this.trackId});

  /// DASH 音轨 id
  final int trackId;

  String get label => switch (this) {
        AudioQuality.q64k => '64K',
        AudioQuality.q132k => '132K',
        AudioQuality.q192k => '192K',
        AudioQuality.qHiRes => 'Hi-Res',
      };

  String get wire => switch (this) {
        AudioQuality.q64k => '64k',
        AudioQuality.q132k => '132k',
        AudioQuality.q192k => '192k',
        AudioQuality.qHiRes => 'hires',
      };

  /// 需要绑定 B 站账号才可选（192K 起）。
  bool get needsBinding =>
      this == AudioQuality.q192k || this == AudioQuality.qHiRes;

  /// 需要大会员才可选（仅 Hi-Res）。
  bool get needsVip => this == AudioQuality.qHiRes;

  /// 给定绑定/会员态下该档是否可选可播（Q1 锁态判定的单一事实源）。
  bool isUnlocked({required bool bound, required bool isVip}) =>
      (!needsBinding || bound) && (!needsVip || isVip);

  /// 给定绑定/会员态下的**最高**可用档（权限变化时的回落目标）：
  /// 解绑 → 132K、大会员过期 → 192K、大会员 → Hi-Res。
  static AudioQuality highestUnlocked({
    required bool bound,
    required bool isVip,
  }) =>
      bound && isVip
          ? AudioQuality.qHiRes
          : bound
              ? AudioQuality.q192k
              : AudioQuality.q132k;

  static AudioQuality fromWire(String? v) => switch (v) {
        '64k' => AudioQuality.q64k,
        '192k' => AudioQuality.q192k,
        'hires' => AudioQuality.qHiRes,
        _ => AudioQuality.q132k,
      };
}

/// 一次播放会话：正在播的专辑 + 完整章节列表 + 当前下标。
class PlaybackSession {
  const PlaybackSession({
    required this.album,
    required this.chapters,
    required this.index,
    this.position = Duration.zero,
    this.autoPlay = false,
  });

  final Album album;
  final List<Chapter> chapters;

  /// 当前章节在 [chapters] 中的下标
  final int index;

  /// 进入会话时的续播位置（秒级精度由调用方保证）
  final Duration position;

  /// 是否开播（false = 只装载不发声，用于冷启动恢复）
  final bool autoPlay;

  Chapter? get chapter =>
      index >= 0 && index < chapters.length ? chapters[index] : null;

  bool get hasNext => index < chapters.length - 1;
  bool get hasPrev => index > 0;

  PlaybackSession copyWith({
    int? index,
    Duration? position,
    bool? autoPlay,
    List<Chapter>? chapters,
  }) =>
      PlaybackSession(
        album: album,
        chapters: chapters ?? this.chapters,
        index: index ?? this.index,
        position: position ?? this.position,
        autoPlay: autoPlay ?? this.autoPlay,
      );
}
