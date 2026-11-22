// M9.0 spike 探针：复现 Edge TTS WebSocket 握手，定位 403 原因。
// 运行：dart run tool/spike/ws_probe.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

const trustedClientToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';

String gec() {
  int nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  int ticks = nowSeconds + 11644473600;
  ticks -= ticks % 300;
  final str = '${ticks * 10000000}$trustedClientToken';
  return sha256.convert(utf8.encode(str)).toString().toUpperCase();
}

Future<void> main(List<String> args) async {
  final variant = args.isNotEmpty ? args[0] : 'a';
  // v2: Sec-MS-GEC-Version=2-x 且 Sec-MS-GEC 为 CS64-SHA256 对（此处无法离线构造，仅测 v1 兼容）
  final gecVersion = variant.startsWith('legacy') ? '1-130.0.2849.68' : '1-143.0.3650.75';
  final url = 'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1'
      '?TrustedClientToken=$trustedClientToken'
      '&ConnectionId=${_uuidHex()}'
      '&Sec-MS-GEC=${gec()}'
      '&Sec-MS-GEC-Version=$gecVersion';
  final headers = <String, String>{
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0',
    'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
    'Accept-Encoding': 'gzip, deflate, br, zstd',
    'Accept-Language': 'en-US,en;q=0.9',
    'Pragma': 'no-cache',
    'Cache-Control': 'no-cache',
  };
  if (variant == 'b') headers.remove('Origin');
  if (variant == 'c') {
    headers['User-Agent'] =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/143.0.0.0 Safari/537.36';
  }
  // ignore: avoid_print
  print('variant=$variant connecting…');
  try {
    final ws = await WebSocket.connect(url, headers: headers).timeout(
      const Duration(seconds: 12),
    );
    // ignore: avoid_print
    print('OK: handshake 101, readyState=${ws.readyState}');
    await ws.close();
  } catch (e) {
    // ignore: avoid_print
    print('FAIL: $e');
  }
  exit(0);
}

String _uuidHex() {
  final r = Random.secure();
  return List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
}
