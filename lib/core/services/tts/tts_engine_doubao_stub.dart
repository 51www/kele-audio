import 'tts_engine.dart';

/// Web 端占位：豆包合成依赖 dart:io WebSocket / 临时文件，阅读/听书仅 Android 提供。
class TtsDoubaoEngine implements TtsEngine {
  TtsDoubaoEngine({required this.cookieProvider});

  final String Function() cookieProvider;

  @override
  String get id => 'doubao';

  @override
  Future<void> start(TtsParams params) async {}

  @override
  void prefetch(String text) {}

  @override
  Future<void> speak(String text) async {
    throw const TtsException('unsupported', 'Web 端不支持豆包听书');
  }

  @override
  Future<void> stop() async {}

  @override
  void resetCache() {}

  @override
  Future<void> testConnection() async {
    throw const TtsException('unsupported', 'Web 端不支持豆包听书');
  }

  @override
  Future<void> dispose() async {}
}
