import 'tts_engine.dart';

/// Web 端占位：MiMo 合成依赖 dart:io 临时文件与 media_kit，阅读/听书仅 Android 提供。
class TtsMimoEngine implements TtsEngine {
  TtsMimoEngine({required this.apiKeyProvider, required this.paramsProvider});

  final String Function() apiKeyProvider;
  final TtsParams Function() paramsProvider;

  @override
  String get id => 'mimo';

  @override
  Future<void> start(TtsParams params) async {}

  @override
  void prefetch(String text) {}

  @override
  Future<void> speak(String text) async {
    throw const TtsException('unsupported', 'Web 端不支持 MiMo 听书');
  }

  @override
  Future<void> stop() async {}

  @override
  void resetCache() {}

  @override
  Future<void> testConnection() async {
    throw const TtsException('unsupported', 'Web 端不支持 MiMo 听书');
  }

  @override
  Future<void> dispose() async {}
}
