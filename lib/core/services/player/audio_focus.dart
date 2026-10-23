import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 音频焦点（PRD **P-07**）：自建原生 MethodChannel。
///
/// 移植自 abts（MIT）`lib/services/audio_focus.dart` + `MainActivity.kt`，
/// 只改了通道前缀（`abts/` → `kele/`）。五个事件的语义：
///
/// | 事件 | 场景 | 播放器动作 |
/// |---|---|---|
/// | `interrupted` | 来电 / 导航播报抢占 | 暂停，**不放弃焦点**，等 `gained` 自动续播 |
/// | `ducked` | 提示音闪避 | 音量 ×0.3（下限保护），不中断 |
/// | `gained` | 打断结束 | 还原音量 + 若之前被打断则续播 |
/// | `lost` | 被其他播放器永久抢占 | 暂停且**不自动恢复** |
/// | `noisy` | 拔耳机 / 蓝牙断开 | 暂停 |
///
/// Web 预览没有原生通道：全部降级为放行（不阻塞播放）。
class AudioFocus {
  AudioFocus();

  static final AudioFocus instance = AudioFocus();

  static const MethodChannel _method = MethodChannel('kele/audio_focus');
  static const EventChannel _events = EventChannel('kele/audio_focus_events');

  StreamSubscription<dynamic>? _sub;

  /// 被永久抢占（其他播放器开始播放）：应暂停且不自动恢复
  void Function()? onFocusLost;

  /// 被暂时打断（来电等）：应暂停并等待恢复
  void Function()? onFocusInterrupted;

  /// 短暂闪避（导航/提示音）：只压低音量，不中断播放
  void Function()? onFocusDucked;

  /// 打断结束、重新拿到焦点：恢复音量并续播
  void Function()? onFocusGained;

  /// 输出设备变为噪音（拔耳机 / 蓝牙断开）：自动暂停
  void Function()? onNoisy;

  bool get _native => !kIsWeb;

  /// 订阅焦点事件（幂等）
  void start() {
    if (_sub != null || !_native) return;
    try {
      _sub = _events.receiveBroadcastStream().listen(
        (e) {
          switch (e) {
            case 'lost':
              onFocusLost?.call();
            case 'interrupted':
              onFocusInterrupted?.call();
            case 'ducked':
              onFocusDucked?.call();
            case 'gained':
              onFocusGained?.call();
            case 'noisy':
              onNoisy?.call();
          }
        },
        onError: (_) {
          // 个别 ROM 不注册通道时静默降级，绝不影响播放
        },
      );
    } catch (_) {
      // 通道不可用（Web / 桌面）：静默
    }
  }

  /// 请求焦点（播放开始时）。失败或不支持一律放行，避免误伤播放。
  Future<bool> request() async {
    if (!_native) return true;
    try {
      return await _method.invokeMethod<bool>('request') ?? false;
    } catch (_) {
      return true;
    }
  }

  Future<void> abandon() async {
    if (!_native) return;
    try {
      await _method.invokeMethod<void>('abandon');
    } catch (_) {
      // 忽略：焦点本就可能已被系统回收
    }
  }

  @mustCallSuper
  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
