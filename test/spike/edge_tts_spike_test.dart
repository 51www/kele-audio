// M9.0 spike：Edge TTS 合成验证（需真实网络，Android 真机口径）。
//
// 结论沉淀（详见 docs/reader-design.md §4.1）：
// - 服务可达性 OK（voices/list 200）；
// - v1 Sec-MS-GEC（纯 SHA-256）已于 2026-10 服务端全面失效（403 实测）；
// - 定版：自建 EdgeTtsClient（MIT）+ edge_tts_token.dart（LGPL 单文件移植）。
// 运行：flutter test test/spike/edge_tts_spike_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kele_audio/core/services/tts/edge_tts_client.dart';

void main() {
  test('EdgeTtsClient（v2 认证）合成中文 mp3', () async {
    final client = EdgeTtsClient(
      voice: 'zh-CN-XiaoxiaoNeural',
      enableLogging: true,
    );
    final bytes = await client.synthesize(
      '可乐听书，M九点零技术验证。日出江花红胜火，春来江水绿如蓝。能不忆江南？',
    );

    expect(bytes.length, greaterThan(10 * 1024),
        reason: '合成产物应大于 10KB（实际 ${bytes.length} bytes）');
    // MP3 头魔数（ID3 或 0xFFEx 帧）
    final isMp3 = bytes[0] == 0xFF || (bytes[0] == 0x49 && bytes[1] == 0x44);
    expect(isMp3, isTrue, reason: '文件头应为 MP3 格式');

    final outPath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}spike_tts_vm.mp3';
    File(outPath).writeAsBytesSync(bytes);
    // ignore: avoid_print
    print('spike: 合成成功 $outPath (${bytes.length} bytes)');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
