import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app/app.dart';
import 'app/di.dart';
import 'core/services/player/audio_service_bridge.dart';
import 'core/services/player/media_bridge.dart';
import 'core/services/system/notification_permission.dart';

/// 入口：先完成本地装配（零网络），再上界面，最后后台预热。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // M9.0：media_kit 全局初始化前置（幂等）。此前由 MediaKitEngine 构造时
  // 惰性触发，早于引擎创建使用 Player 实例（如 spike 页）会抛异常。
  MediaKit.ensureInitialized();

  // M10：PDFium 初始化（幂等）。失败不阻塞启动，只影响 PDF 导入。
  try {
    await pdfrxFlutterInitialize();
  } catch (e) {
    debugPrint('[main] pdfrx 初始化失败，PDF 导入不可用：$e');
  }

  // 系统媒体会话（P-01 后台 / P-02 锁屏通知 / P-06 线控）：
  // 移动端接 audio_service；Web 或初始化失败一律降级 Noop，**播放不受影响**。
  MediaSessionBridge mediaBridge = NoopMediaBridge();
  if (!kIsWeb) {
    try {
      final bridge = AudioServiceBridge();
      await AudioService.init(
        builder: () => bridge,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.kele.audio.channel.audio',
          androidNotificationChannelName: '可乐听书',
          androidNotificationChannelDescription: '播放有声内容',
          androidNotificationIcon: 'mipmap/ic_launcher',
          // 暂停（含来电打断）时保留前台服务与通知（PRD §7.5 配置项，
          // 用户可在「我的」调整）。audio_service 要求 ongoing 必须为 false。
          androidNotificationOngoing: false,
          androidStopForegroundOnPause: false,
          androidNotificationClickStartsActivity: true,
        ),
      ).timeout(const Duration(seconds: 6));
      mediaBridge = bridge;
    } catch (e) {
      debugPrint('[main] audio service init 失败，降级 Noop：$e');
    }
  }

  final services = await AppServices.bootstrap(mediaBridge: mediaBridge);
  runApp(KeleApp(services: services));
  services.warmupInBackground();

  // M9.3：Android 13+ 首次进入申请通知权限（后台/锁屏听书的通知依赖）。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(NotificationPermission.ensure());
  });
}
