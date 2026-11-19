// kele-audio — MIT License
//
// 豆包 Web TTS 轻量客户端（实验性引擎，仅供个人学习自用）。
// 协议依据 callmerio/doubao-tts（MIT）公开实现：走豆包网页端
// wss://ws-samantha.doubao.com/samantha/audio/tts，登录态 Cookie 放在
// WebSocket 握手 Header，参数放在 URL query，连接后依次发 text / finish 帧。
//
// 这是非官方私有接口，接口形态与风控策略随时可能变更，不保证长期可用。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// 豆包 TTS 合成客户端（纯 Dart，免密钥，使用登录态 Cookie）。
class DoubaoTtsClient {
  DoubaoTtsClient({
    required this.cookie,
    this.speaker = _defaultSpeaker,
    // 豆包 Web 端点只接受 aac / wav；传 mp3 会被拒（710020702 系统错误）。
    this.format = 'aac',
    this.rate = 0,
    this.pitch = 0,
    this.enableLogging = false,
    this.connectionTimeout = const Duration(seconds: 20),
    this.idleTimeout = const Duration(seconds: 20),
    this.sentenceGrace = const Duration(milliseconds: 2500),
    this.overallTimeout = const Duration(seconds: 90),
    this.minRequestInterval = const Duration(seconds: 2),
  });

  static const _wsUrl =
      'wss://ws-samantha.doubao.com/samantha/audio/tts';
  static const _defaultSpeaker =
      'zh_female_taozi_conversation_v4_wvae_bigtts';
  static const _userAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Safari/537.36';

  final String cookie;
  final String speaker;
  final String format;
  final int rate;
  final int pitch;
  final bool enableLogging;
  final Duration connectionTimeout;
  final Duration idleTimeout;
  final Duration sentenceGrace;
  final Duration overallTimeout;
  final Duration minRequestInterval;

  /// 合成一段文本，返回完整音频字节（默认 AAC）。
  ///
  /// 内置两层限流保护：相邻请求最小间隔 [minRequestInterval]，以及接收静默
  /// 判定结束。豆包网页端有风控，频繁请求可能被拦截，不宜高并发调用。
  Future<Uint8List> synthesize(String text) async {
    final normalizedCookie = cookie.trim();
    if (normalizedCookie.isEmpty) {
      throw const DoubaoTtsException(
        'auth',
        '请先设置豆包 Cookie（sessionid / sid_guard / uid_tt）',
      );
    }

    await DoubaoTtsThrottle.instance.wait(baseInterval: minRequestInterval);

    final chunks = <int>[];
    String? remoteError;
    var sawSentenceEnd = false;
    WebSocket? socket;
    Timer? idleTimer;
    var finished = false;
    final completer = Completer<void>();

    void finalize() {
      if (finished) return;
      finished = true;
      idleTimer?.cancel();
      if (!completer.isCompleted) completer.complete();
    }

    void armIdle() {
      idleTimer?.cancel();
      idleTimer =
          Timer(sawSentenceEnd ? sentenceGrace : idleTimeout, finalize);
    }

    void handleMessage(dynamic message) {
      if (message is List<int>) {
        chunks.addAll(message); // 二进制帧 = 音频数据
        armIdle();
        return;
      }
      if (message is! String) return;
      Map<String, dynamic> data;
      try {
        final decoded = jsonDecode(message);
        if (decoded is! Map) return;
        data = Map<String, dynamic>.from(decoded);
      } catch (_) {
        return;
      }
      final event = data['event']?.toString() ?? '';
      if (event == 'error') {
        remoteError = data['message']?.toString() ?? '豆包返回错误';
        finalize();
        return;
      }
      final code = data['code'];
      if (code is num && code != 0) {
        remoteError = data['message']?.toString() ?? '豆包返回错误码 $code';
        finalize();
        return;
      }
      if (event == 'sentence_start') {
        // 多句文本：新句子开始，回到较长的静默窗口，避免中途被误判结束。
        sawSentenceEnd = false;
        armIdle();
      } else if (event == 'sentence_end') {
        sawSentenceEnd = true;
        if (chunks.isNotEmpty) armIdle();
      }
    }

    try {
      final ws = await _connect(normalizedCookie);
      socket = ws;
      ws.listen(
        handleMessage,
        onDone: finalize,
        onError: (Object e) {
          remoteError = 'WebSocket 错误：$e';
          finalize();
        },
        cancelOnError: true,
      );
      // 连接后依次发送待合成文本与结束信号（参数全部在 URL 中）。
      ws.add(jsonEncode({'event': 'text', 'text': text}));
      ws.add(jsonEncode({'event': 'finish'}));
      armIdle();

      await completer.future.timeout(overallTimeout, onTimeout: () {
        remoteError ??= '豆包合成超时';
        finalize();
      });

      if (remoteError != null) {
        throw DoubaoTtsException('server_error', remoteError!);
      }
      final bytes = Uint8List.fromList(chunks);
      if (bytes.isEmpty) {
        throw const DoubaoTtsException('empty_audio', '豆包未返回音频数据');
      }
      DoubaoTtsThrottle.instance.noteSuccess();
      _log('合成完成：${bytes.length} bytes');
      return bytes;
    } on DoubaoTtsException {
      rethrow;
    } catch (e) {
      throw DoubaoTtsException('failed', _cleanError(e));
    } finally {
      idleTimer?.cancel();
      try {
        await socket?.close();
      } catch (_) {}
    }
  }

  Future<WebSocket> _connect(String cookieHeader) async {
    final url = _buildUrl();
    _log('connect: ${url.substring(0, url.indexOf('?'))}');
    final uri = Uri.parse(url);
    final requestUri = uri.replace(
      scheme: uri.scheme == 'wss' ? 'https' : 'http',
    );
    final httpClient = HttpClient()..userAgent = _userAgent;
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
          List<int>.generate(16, (_) => Random.secure().nextInt(256)),
        ),
      );
      request.headers.set('Sec-WebSocket-Version', '13');
      request.headers.set(
        'Sec-WebSocket-Extensions',
        'permessage-deflate; client_max_window_bits',
      );
      request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
      request.headers.set('Origin', 'https://www.doubao.com');
      request.headers.set('Accept-Language', 'zh-CN,zh;q=0.9,en;q=0.8');
      request.headers.set('Cache-Control', 'no-cache');
      request.headers.set('Pragma', 'no-cache');

      final response =
          await request.close().timeout(connectionTimeout);
      if (response.statusCode != HttpStatus.switchingProtocols) {
        // 握手被拒时服务端会返回 JSON body（含真实错误码，如 710020702 /
        // 710012001 等）。读出来并解析，否则只报 HTTP 状态码无法定位。
        var body = '';
        try {
          body = await response
              .transform(utf8.decoder)
              .join()
              .timeout(const Duration(seconds: 3));
        } catch (_) {}
        var detail = '';
        try {
          final decoded = jsonDecode(body);
          if (decoded is Map) {
            final code = decoded['code']?.toString() ?? '';
            final msg = decoded['msg']?.toString() ??
                decoded['message']?.toString() ??
                '';
            detail = [code, msg].where((s) => s.isNotEmpty).join(' ');
          }
        } catch (_) {
          detail = body.length > 160 ? body.substring(0, 160) : body;
        }
        // 非 101 基本都是风控/限流，通知全局节流器退避，避免连续重试撞墙。
        DoubaoTtsThrottle.instance.noteFailure();
        throw DoubaoTtsException(
          'rate_limited',
          '豆包请求被拦截（HTTP ${response.statusCode}'
              '${detail.isNotEmpty ? ' · $detail' : ''}）。'
              '这是豆包的风控限流，请稍等片刻再试，或改用 Edge 朗读',
        );
      }
      final socket = await response.detachSocket().timeout(connectionTimeout);
      return WebSocket.fromUpgradedSocket(
        socket,
        serverSide: false,
        compression: CompressionOptions.compressionDefault,
      );
    } on DoubaoTtsException {
      rethrow;
    } catch (e) {
      throw DoubaoTtsException('connection_failed', _cleanError(e));
    } finally {
      httpClient.close(force: true);
    }
  }

  /// 构造 WebSocket URL。参数含义参考豆包网页端协议；device/web/tab id 每次
  /// 连接随机生成，模拟一次全新的网页会话。
  String _buildUrl() {
    final deviceId = _randomId19();
    final webId = _randomId19();
    final params = <String, Object>{
      'speaker': speaker,
      'format': format,
      'speech_rate': rate,
      'pitch': pitch,
      'version_code': 20800,
      'language': 'zh',
      'device_platform': 'web',
      'aid': 497858,
      'real_aid': 497858,
      'pkg_type': 'release_version',
      'device_id': deviceId,
      'pc_version': '2.46.3',
      'web_id': webId,
      'tea_uid': webId,
      'region': '',
      'sys_region': '',
      'samantha_web': 1,
      'use-olympus-account': 1,
      'web_tab_id': _uuid4(),
    };
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value.toString())}')
        .join('&');
    return '$_wsUrl?$query';
  }

  static String _randomId19() {
    // 协议期望 74 开头的 19 位十进制 id。Random.nextInt 上限为 2^32，
    // 拆成两段拼接：74 + 8 位 + 9 位 = 19 位。
    return '74${Random.secure().nextInt(100000000).toString().padLeft(8, '0')}'
        '${Random.secure().nextInt(1000000000).toString().padLeft(9, '0')}';
  }

  static String _uuid4() {
    final random = Random.secure();
    String hex(int count) => List<int>.generate(
          count,
          (_) => random.nextInt(16),
        ).map((v) => v.toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-'
        '${(random.nextInt(4) + 8).toRadixString(16)}${hex(3)}-${hex(12)}';
  }

  static String _cleanError(Object error) {
    final raw = error.toString();
    return raw.replaceFirst(RegExp(r'^\w+Exception\([^)]*\):\s*'), '');
  }

  void _log(String message) {
    if (enableLogging) {
      // ignore: avoid_print
      print('[doubao_tts_client] $message');
    }
  }
}

/// 进程级共享节流器。
///
/// 豆包网页端有风控：短时间内连续握手会被拒（HTTP 非 101，表现为
/// 「WebSocket 升级失败」）。引擎每次合成都会新建 client，若把节流时间戳
/// 放在实例上则完全失效，因此用单例在进程内统一排队，并在检测到风控后
/// 自动退避，逐步拉长间隔。
class DoubaoTtsThrottle {
  DoubaoTtsThrottle._();

  static final DoubaoTtsThrottle instance = DoubaoTtsThrottle._();

  DateTime? _lastRequestAt;
  Duration _penalty = Duration.zero;
  int _consecutiveFailures = 0;
  final Duration _maxPenalty = const Duration(seconds: 30);

  /// 等待到可以发起下一次握手。
  Future<void> wait({required Duration baseInterval}) async {
    final now = DateTime.now();
    final last = _lastRequestAt;
    var requiredGap = baseInterval + _penalty;
    if (last != null) {
      final elapsed = now.difference(last);
      if (elapsed < requiredGap) {
        await Future<void>.delayed(requiredGap - elapsed);
      }
    }
    _lastRequestAt = DateTime.now();
  }

  /// 请求被风控拒绝时调用，累加退避；连续成功后由 [noteSuccess] 逐步恢复。
  void noteFailure() {
    _consecutiveFailures++;
    _penalty = Duration(
      seconds: (_penalty.inSeconds * 2 + 3).clamp(0, _maxPenalty.inSeconds),
    );
  }

  void noteSuccess() {
    if (_consecutiveFailures == 0 && _penalty == Duration.zero) return;
    _consecutiveFailures = 0;
    _penalty = Duration.zero;
  }
}

class DoubaoTtsException implements Exception {
  const DoubaoTtsException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'DoubaoTtsException($code): $message';
}
