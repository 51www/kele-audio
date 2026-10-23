import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/di.dart';

/// 入口：先完成本地装配（零网络），再上界面，最后后台预热。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await AppServices.bootstrap();
  runApp(KeleApp(services: services));
  services.warmupInBackground();
}
