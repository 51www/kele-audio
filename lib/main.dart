import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/di.dart';
import 'core/services/player/audio_service_bridge.dart';
import 'core/services/player/media_bridge.dart';

/// 入口：先完成本地装配（零网络），再上界面，最后后台预热。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
}
