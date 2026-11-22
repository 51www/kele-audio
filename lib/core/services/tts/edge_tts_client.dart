// kele-audio — MIT License
//
// Edge TTS 轻量客户端（M9.0 spike 定版实现）。
// 协议依据公开的 Edge Read Aloud WebSocket 约定自写实现；
// v2 令牌算法见 edge_tts_token.dart（LGPL-3.0 单文件移植）。
// 报文格式参考 flutter_edge_tts（MIT）的协议约定。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'edge_tts_token.dart';

/// Edge TTS 合成客户端（纯 Dart，免密钥）。
///
/// 用法：
/// ```dart
/// final client = EdgeTtsClient(voice: 'zh-CN-XiaoxiaoNeural');
/// final mp3 = await client.synthesize('你好，世界');
/// ```
class EdgeTtsClient {
  EdgeTtsClient({
    this.voice = 'zh-CN-XiaoxiaoNeural',
    this.rate = '+0%',
    this.pitch = '+0Hz',
    this.volume = '+0%',
    this.enableLogging = false,
    this.connectionTimeout = const Duration(seconds: 20),
  });

  static const _trustedClientToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const _chromiumFullVersion = '143.0.3650.75';
  static const _secMsGecVersion = '2-$_chromiumFullVersion';
  static const _wssUrl =
      'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1';
  static const _defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0';
  static const _defaultOrigin =
      'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold';
  static const _outputFormat = 'audio-24khz-48kbitrate-mono-mp3';

  final String voice;
  final String rate;
  final String pitch;
  final String volume;
  final bool enableLogging;
  final Duration connectionTimeout;

  /// 合成一段文本，返回完整 MP3 字节。
  Future<Uint8List> synthesize(String text) async {
    final chunks = <int>[];
    await for (final event in synthesizeStream(text)) {
      if (event is EdgeTtsAudioChunk) chunks.addAll(event.data);
    }
    final bytes = Uint8List.fromList(chunks);
    if (bytes.isEmpty) {
      throw const EdgeTtsException('empty_audio', '服务未返回音频数据');
    }
    return bytes;
  }

  /// 流式合成（音频分块事件）。
  Stream<EdgeTtsStreamEvent> synthesizeStream(String text) {
    late final StreamController<EdgeTtsStreamEvent> controller;
    WebSocket? socket;

    Future<void> cleanup() async {
      try {
        await socket?.close();
      } catch (_) {}
      socket = null;
      if (!controller.isClosed) await controller.close();
    }

    controller = StreamController<EdgeTtsStreamEvent>(
      onListen: () {
        () async {
          try {
            socket = await _connect();
            socket!.listen(
              (message) {
                final event = _parseMessage(message);
                if (event == null) return;
                if (event is _EdgeTtsTurnEnd) {
                  cleanup();
                } else if (event is EdgeTtsAudioChunk) {
                  controller.add(event);
                }
              },
              onDone: cleanup,
              onError: (Object e) {
                if (!controller.isClosed) {
                  controller.addError(EdgeTtsException('websocket_error', '$e'));
                }
                cleanup();
              },
              cancelOnError: true,
            );
            final timestamp = _jsTimestamp();
            socket!.add(_speechConfigMessage(timestamp));
            socket!.add(_ssmlRequest(text, _randomHex(16), timestamp));
          } catch (e) {
            if (!controller.isClosed) {
              controller.addError(EdgeTtsException('connection_failed', '$e'));
            }
            await cleanup();
          }
        }();
      },
      onCancel: cleanup,
    );
    return controller.stream;
  }

  Future<WebSocket> _connect() async {
    final url = '$_wssUrl'
        '?TrustedClientToken=$_trustedClientToken'
        '&Sec-MS-GEC=${EdgeTtsUtils.generateSecMsGecV2(_trustedClientToken)}'
        '&Sec-MS-GEC-Version=$_secMsGecVersion'
        '&ConnectionId=${_randomHex(16)}';
    _log('connect: $url');

    // 手动完成 WebSocket 升级握手：dart:io WebSocket.connect 的自动握手
    // （无 permessage-deflate 协商等）会被 Edge 服务端 403（spike 实测）。
    final uri = Uri.parse(url);
    final requestUri = uri.replace(
      scheme: uri.scheme == 'wss' ? 'https' : 'http',
    );
    final httpClient = HttpClient()..userAgent = _defaultUserAgent;
    try {
      final request = await httpClient
          .openUrl('GET', requestUri)
          .timeout(connectionTimeout);
      request.headers.set(HttpHeaders.hostHeader, uri.host);
      request.headers.set(HttpHeaders.upgradeHeader, 'websocket');
      request.headers.set(HttpHeaders.connectionHeader, 'Upgrade');
      request.headers.set(
        'Sec-WebSocket-Key',
        base64Encode(
          List<int>.generate(16, (_) => _secureRandom.nextInt(256)),
        ),
      );
      request.headers.set('Sec-WebSocket-Version', '13');
      request.headers.set(
        'Sec-WebSocket-Extensions',
        'permessage-deflate; client_max_window_bits',
      );
      const extraHeaders = {
        'Origin': _defaultOrigin,
        'Accept-Encoding': 'gzip, deflate, br, zstd',
        'Accept-Language': 'en-US,en;q=0.9',
        'Pragma': 'no-cache',
        'Cache-Control': 'no-cache',
      };
      extraHeaders.forEach(request.headers.set);

      final response =
          await request.close().timeout(connectionTimeout);
      if (response.statusCode != HttpStatus.switchingProtocols) {
        await response.drain<void>();
        throw EdgeTtsException(
          'websocket_upgrade_failed',
          'WebSocket 升级失败：HTTP ${response.statusCode}',
        );
      }
      final socket = await response.detachSocket().timeout(connectionTimeout);
      return WebSocket.fromUpgradedSocket(
        socket,
        serverSide: false,
        compression: CompressionOptions.compressionDefault,
      );
    } on EdgeTtsException {
      rethrow;
    } catch (e) {
      throw EdgeTtsException('connection_failed', '$e');
    } finally {
      httpClient.close(force: true);
    }
  }

  static final Random _secureRandom = Random.secure();

  String _speechConfigMessage(String timestamp) {
    final body = jsonEncode({
      'context': {
        'synthesis': {
          'audio': {
            'metadataoptions': {
              'sentenceBoundaryEnabled': 'false',
              'wordBoundaryEnabled': 'false',
            },
            'outputFormat': _outputFormat,
          },
        },
      },
    });
    return 'X-Timestamp:$timestamp\r\n'
        'Content-Type:application/json; charset=utf-8\r\n'
        'Path:speech.config\r\n\r\n$body\r\n';
  }

  String _ssmlRequest(String text, String requestId, String timestamp) {
    final locale =
        RegExp(r'\w{2}-\w{2}').firstMatch(voice)?.group(0) ?? 'zh-CN';
    final ssml =
        '<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" '
        'xmlns:mstts="https://www.w3.org/2001/mstts" xml:lang="$locale">'
        '<voice name="$voice">'
        '<prosody pitch="$pitch" rate="$rate" volume="$volume">'
        '${_xmlEscape(text)}'
        '</prosody></voice></speak>';
    return 'X-RequestId:$requestId\r\n'
        'Content-Type:application/ssml+xml\r\n'
        'X-Timestamp:${timestamp}Z\r\n'
        'Path:ssml\r\n\r\n$ssml';
  }

  /// 解析一帧服务端消息：返回 null 表示忽略，[EdgeTtsAudioChunk] 为音频，
  /// [_EdgeTtsTurnEnd] 表示本轮合成结束。
  EdgeTtsStreamEvent? _parseMessage(dynamic message) {
    final Uint8List bytes;
    if (message is String) {
      bytes = Uint8List.fromList(utf8.encode(message));
    } else if (message is List<int>) {
      bytes = Uint8List.fromList(message);
    } else {
      throw EdgeTtsException('invalid_message', '${message.runtimeType}');
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    if (text.contains('Path:turn.end')) {
      _log('turn.end');
      return const _EdgeTtsTurnEnd();
    }
    if (text.contains('Path:audio\r\n')) {
      final delimBytes = utf8.encode('Path:audio\r\n');
      final idx = _indexOfSublist(bytes, delimBytes);
      if (idx >= 0) {
        return EdgeTtsAudioChunk(
          Uint8List.sublistView(bytes, idx + delimBytes.length),
        );
      }
    }
    return null; // turn.start / response / audio.metadata 等
  }

  void _log(String message) {
    if (enableLogging) {
      // ignore: avoid_print
      print('[edge_tts_client] $message');
    }
  }
}

/// JS 风格时间戳（协议要求，如 "Tue Nov 04 2026 12:00:00 GMT+0000 (...)"）。
String _jsTimestamp() {
  final utc = DateTime.now().toUtc();
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${weekdays[utc.weekday - 1]} ${months[utc.month - 1]} '
      '${utc.day.toString().padLeft(2, '0')} ${utc.year} '
      '${utc.hour.toString().padLeft(2, '0')}:'
      '${utc.minute.toString().padLeft(2, '0')}:'
      '${utc.second.toString().padLeft(2, '0')} GMT+0000 '
      '(Coordinated Universal Time)';
}

/// 在 [source] 中查找 [pattern] 首次出现的字节下标，找不到返回 -1。
int _indexOfSublist(List<int> source, List<int> pattern) {
  if (pattern.isEmpty || source.length < pattern.length) return -1;
  outer:
  for (var i = 0; i <= source.length - pattern.length; i++) {
    for (var j = 0; j < pattern.length; j++) {
      if (source[i + j] != pattern[j]) continue outer;
    }
    return i;
  }
  return -1;
}

String _xmlEscape(String input) => input
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

String _randomHex(int byteCount) {
  final random = Random.secure();
  return List<int>.generate(byteCount * 2, (_) => random.nextInt(16))
      .map((v) => v.toRadixString(16))
      .join();
}

/// 合成流事件。
sealed class EdgeTtsStreamEvent {
  const EdgeTtsStreamEvent();
}

/// 音频分块（MP3 字节）。
class EdgeTtsAudioChunk extends EdgeTtsStreamEvent {
  const EdgeTtsAudioChunk(this.data);

  final Uint8List data;
}

class _EdgeTtsTurnEnd extends EdgeTtsStreamEvent {
  const _EdgeTtsTurnEnd();
}

class EdgeTtsException implements Exception {
  const EdgeTtsException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'EdgeTtsException($code): $message';
}
