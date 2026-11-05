/// M9.0 spike：Edge TTS 合成入口（Android 真机专用，dart:io WebSocket）。
///
/// 定版结论见 docs/reader-design.md §4.1：
/// 自建 EdgeTtsClient（MIT）+ edge_tts_token.dart（LGPL-3.0 单文件移植）。
library;

import 'edge_tts_spike_io.dart';

/// 合成一段中文语音 mp3 到 [outPath]，返回实际写盘路径。
Future<String> synthesizeEdgeTts(String text, String outPath) =>
    synthesize(text, outPath);
