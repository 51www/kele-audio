import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 通知权限状态（Android 13+ `POST_NOTIFICATIONS`）。
///
/// 后台/锁屏听书依赖媒体通知，权限被拒时音频仍可播放，但通知栏与锁屏
/// 控制不可用，阅读页听书控制条据此展示降级提示并提供「去开启」入口。
/// 非 Android 平台或 Android 13 以下一律视为已授权。
class NotificationPermission {
  NotificationPermission._();

  static const MethodChannel _channel = MethodChannel(
    'com.kele.audio/notifications',
  );

  /// 最近一次查询/申请的结果，供 UI 监听。
  static final ValueNotifier<bool> granted = ValueNotifier<bool>(true);

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 查询当前授权状态（不弹窗）。
  static Future<bool> check() async {
    if (!_supported) return true;
    try {
      final value = await _channel.invokeMethod<bool>('status') ?? true;
      granted.value = value;
      return value;
    } catch (e) {
      debugPrint('[notification] 查询通知权限失败：$e');
      return true;
    }
  }

  /// 申请权限（仅 Android 13+ 首次有系统弹窗）。
  static Future<bool> request() async {
    if (!_supported) return true;
    try {
      final value = await _channel.invokeMethod<bool>('request') ?? true;
      granted.value = value;
      return value;
    } catch (e) {
      debugPrint('[notification] 申请通知权限失败：$e');
      return true;
    }
  }

  /// 启动时调用：未授权则申请一次，返回最终状态。
  static Future<bool> ensure() async {
    if (!_supported) return true;
    final current = await check();
    if (current) return true;
    return request();
  }

  /// 跳转系统「应用通知设置」，供用户手动开启。
  static Future<void> openSettings() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('openSettings');
    } catch (e) {
      debugPrint('[notification] 打开通知设置失败：$e');
    }
  }
}
