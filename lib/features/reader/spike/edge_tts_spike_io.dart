import 'dart:io';
import 'dart:typed_data';

import '../../../core/services/tts/edge_tts_client.dart';

/// M9.0 spike：Edge TTS 合成（Android 真机）→ mp3 落盘。
Future<String> synthesize(String text, String outPath) async {
  final client = EdgeTtsClient(voice: 'zh-CN-XiaoxiaoNeural');
  final Uint8List bytes;
  try {
    bytes = await client.synthesize(text);
  } finally {
    // 一次性客户端：用完即弃（M9.3 会改为会话内复用）
  }
  final file = File(outPath);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes, flush: true);
  if (bytes.length < 1024) {
    throw StateError('Edge TTS 合成产物异常：${bytes.length} bytes');
  }
  return outPath;
}
