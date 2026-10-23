import 'dart:async';

/// 播放内核抽象（M2 任务 3）。
///
/// 生产实现为 `media_kit`（`media_kit_engine.dart`，双平台一份代码）：
/// - **原生（Android）**：`open(url, httpHeaders:)` 原生带 UA/Referer 取流，
///   这是 B 站 CDN 必需的（AGENT.md 技术决策）；
/// - **Web 预览**：media_kit 自带 HTMLVideoElement 后端 + `tool/dev_proxy.mjs`
///   音频反代 —— 浏览器禁止设置 UA/Referer 这类「禁止头」，由反代补上。
///
/// 抽象出这一层是为了单测：注入假内核即可验证 `PlayerService` 的编排逻辑，
/// 不会真的创建 media_kit。
///
/// 两套实现对外行为一致：进度/时长/播放态三路流、完成事件、错误事件。
abstract class PlayerEngine {
  /// 播放位置（播放中约 250ms 一次）
  Stream<Duration> get position;

  /// 媒体总时长（拿到时长时发一次）
  Stream<Duration> get duration;

  /// 播放/暂停状态
  Stream<bool> get playing;

  /// 缓冲状态
  Stream<bool> get buffering;

  /// 播放自然结束（一章播完）
  Stream<void> get completed;

  /// 播放错误（403/超时/网络中断 → 上层据此走 P-05 自愈）
  Stream<String> get errors;

  Duration get positionValue;
  Duration get durationValue;
  bool get isPlaying;
  double get rate;
  double get volume;

  /// 打开一个音源。
  ///
  /// [headers] 仅原生端生效（UA/Referer）；Web 端由反代补全，
  /// 这里仍然透传给实现，便于实现层拼进反代参数。
  Future<void> open({
    required String url,
    Map<String, String>? headers,
    bool autoplay = true,
    Duration startAt = Duration.zero,
  });

  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration to);
  Future<void> setRate(double v);
  Future<void> setVolume(double v);
  Future<void> dispose();
}
