import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 一次性「下载完成」通知（离线缓存 / 版本更新包）。
///
/// 与后台播放用的媒体通知分属两个 Android 通知渠道：媒体渠道保持静默
/// （不再反复「叮」），下载渠道带声——缓存完成、更新包下载完成是用户
/// 主动发起且低频的事件，理应提醒。
///
/// 走 MethodChannel 由原生发通知：不引入第三方插件、Web 端安全降级。
class DownloadNotification {
  DownloadNotification._();

  static const MethodChannel _channel = MethodChannel('com.kele.audio/notifier');

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 发一条带声的下载完成通知。任何失败都静默忽略（通知是锦上添花，
  /// 不能影响下载/更新主流程）。
  static Future<void> showDownloadComplete(String title, String body) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('showDownloadComplete', <String, Object>{
        'title': title,
        'body': body,
      });
    } catch (e) {
      debugPrint('[notifier] 下载完成通知失败：$e');
    }
  }
}
