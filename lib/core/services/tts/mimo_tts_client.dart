import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import 'tts_engine.dart';

/// MiMo 内置兜底音色（接口 400 探测失败时使用，全部可读中文）。
const List<TtsVoice> mimoFallbackVoices = [
  TtsVoice(id: 'mimo_default', name: '默认'),
  TtsVoice(id: '冰糖', name: '冰糖'),
  TtsVoice(id: '茉莉', name: '茉莉'),
  TtsVoice(id: '苏打', name: '苏打'),
  TtsVoice(id: '白桦', name: '白桦'),
  TtsVoice(id: 'Mia', name: 'Mia'),
  TtsVoice(id: 'Chloe', name: 'Chloe'),
  TtsVoice(id: 'Milo', name: 'Milo'),
  TtsVoice(id: 'Dean', name: 'Dean'),
];

/// 音色 id → 展示名（未知 id 原样展示）。
String mimoVoiceLabel(String id) {
  for (final voice in mimoFallbackVoices) {
    if (voice.id == id) return voice.name;
  }
  return id;
}

/// 日志/提示里只露首尾，绝不回显完整 Key。
String maskApiKey(String key) {
  if (key.isEmpty) return '';
  if (key.length <= 8) return '已配置';
  return '${key.substring(0, 4)}…${key.substring(key.length - 4)}';
}

/// 小米 MiMo TTS（OpenAI 兼容 `/chat/completions`）。
///
/// - 24 kHz 单声道；非流式，100 字约 6.5 秒、500 字约 84 秒。
/// - 长输入会多读音节，因此调用方必须先把文本切成短句（见 MimoTextSplitter）。
class MimoTtsClient {
  MimoTtsClient({Dio? dio}) : _dio = dio ?? Dio();

  /// 可用 `--dart-define=MIMO_BASE_URL=...` 覆盖（仅用于故障注入测试，正常构建保持默认）。
  static const String baseUrl = String.fromEnvironment(
    'MIMO_BASE_URL',
    defaultValue: 'https://api.xiaomimimo.com/v1',
  );
  static const String model = 'mimo-v2.5-tts';

  /// 单次请求超时（接口实测短文本 6~10 秒，30 秒足够且能兜住网络抖动）。
  static const Duration timeout = Duration(seconds: 30);

  /// 最多重试 2 次（指数退避 1s / 2s）。
  static const int maxRetries = 2;

  static const String styleInstruction =
      '请用自然、清晰、有感情的中文朗读下面的文本，保持原文的停顿与语气，'
      '不要增删内容，不要读出提示词。';

  final Dio _dio;

  Future<Uint8List> synthesize({
    required String apiKey,
    required String text,
    required String voice,
    CancelToken? cancelToken,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw const TtsException(
        'config',
        '未配置 MiMo 朗读 API Key，请到「设置 → 本地书 · 听书 → MiMo 朗读」填写',
      );
    }
    Object? lastError;
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final data = await _post(
          apiKey: apiKey,
          text: text,
          voice: voice,
          cancelToken: cancelToken,
        );
        return _extractAudio(data);
      } on TtsException catch (e) {
        if (e.code == 'cancelled' ||
            e.code == 'auth' ||
            e.code == 'config' ||
            e.code == 'voice_invalid' ||
            e.code == 'request' ||
            e.code == 'empty_audio') {
          rethrow;
        }
        lastError = e;
        if (attempt == maxRetries) break;
        await Future<void>.delayed(Duration(milliseconds: 1000 * (attempt + 1)));
        if (cancelToken?.isCancelled == true) {
          throw const TtsException('cancelled', '已取消 MiMo 请求');
        }
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) {
          throw const TtsException('cancelled', '已取消 MiMo 请求');
        }
        lastError = e;
        if (attempt == maxRetries) break;
        await Future<void>.delayed(Duration(milliseconds: 1000 * (attempt + 1)));
      }
    }
    throw TtsException(
      'network',
      'MiMo 请求失败：${_friendlyError(lastError, apiKey)}',
    );
  }

  Future<dynamic> _post({
    required String apiKey,
    required String text,
    required String voice,
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.post<dynamic>(
      '$baseUrl/chat/completions',
      data: {
        'model': model,
        'messages': [
          {'role': 'user', 'content': styleInstruction},
          {'role': 'assistant', 'content': text},
        ],
        'audio': {'format': 'wav', 'voice': voice},
        'stream': false,
      },
      options: Options(
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        sendTimeout: timeout,
        receiveTimeout: timeout,
        connectTimeout: timeout,
        responseType: ResponseType.json,
        validateStatus: (status) => status != null && status < 500,
      ),
      cancelToken: cancelToken,
    );
    final status = response.statusCode ?? 0;
    if (status >= 400) {
      final body = _bodyText(response.data);
      if (status == 401 || status == 403) {
        throw const TtsException(
          'auth',
          'MiMo 鉴权失败：API Key 无效或已过期，请在设置页重新填写',
        );
      }
      if (status == 400) {
        if (body.toLowerCase().contains('voice')) {
          throw TtsException(
            'voice_invalid',
            'MiMo 音色不可用：${_truncate(body)}',
          );
        }
        throw TtsException('request', 'MiMo 请求被拒绝：${_truncate(body)}');
      }
      throw TtsException('request', 'MiMo 返回 $status：${_truncate(body)}');
    }
    return response.data;
  }

  /// 探测可用音色：故意传非法音色触发 400，从报错原文解析清单。
  ///
  /// 失败时抛 [TtsException]，调用方回退到 [mimoFallbackVoices]。
  Future<List<String>> probeVoices({required String apiKey}) async {
    if (apiKey.trim().isEmpty) {
      throw const TtsException('config', '未配置 MiMo 朗读 API Key');
    }
    try {
      final response = await _dio.post<dynamic>(
        '$baseUrl/chat/completions',
        data: {
          'model': model,
          'messages': [
            {'role': 'user', 'content': styleInstruction},
            {'role': 'assistant', 'content': '你好'},
          ],
          'audio': {'format': 'wav', 'voice': '__mimo_probe_invalid__'},
          'stream': false,
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          sendTimeout: timeout,
          receiveTimeout: timeout,
          connectTimeout: timeout,
          validateStatus: (_) => true,
        ),
      );
      final body = _bodyText(response.data);
      final voices = _parseAvailableVoices(body);
      if (voices.isEmpty) {
        // 仅打印服务端报错原文（不含 Key），便于修正解析规则。
        final raw = response.data is String
            ? response.data as String
            : jsonEncode(response.data);
        debugPrint('[tts:mimo] 音色探测原文：${_truncate(raw)}');
        throw const TtsException('probe_failed', 'MiMo 未返回可用音色清单');
      }
      return voices;
    } on TtsException {
      rethrow;
    } on DioException catch (e) {
      throw TtsException('probe_failed', _friendlyError(e, apiKey));
    }
  }

  static List<String> _parseAvailableVoices(String body) {
    final match = RegExp(
      r'Available voices\s*:\s*\[([^\]]*)\]',
      caseSensitive: false,
    ).firstMatch(body);
    if (match == null) return const [];
    return match
        .group(1)!
        .split(',')
        .map((e) => e.trim().replaceAll('"', '').replaceAll("'", '').trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  static Uint8List _extractAudio(dynamic data) {
    dynamic root = data;
    if (root is String) {
      try {
        root = jsonDecode(root);
      } catch (_) {
        throw const TtsException('empty_audio', 'MiMo 返回内容无法解析');
      }
    }
    if (root is! Map) {
      throw const TtsException('empty_audio', 'MiMo 返回内容无法解析');
    }
    final choices = root['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const TtsException('empty_audio', 'MiMo 未返回朗读音频');
    }
    final first = choices.first;
    final message = first is Map ? first['message'] : null;
    final audio = message is Map ? message['audio'] : null;
    final encoded = audio is Map
        ? audio['data']
        : (first is Map ? first['audio'] is Map ? (first['audio'] as Map)['data'] : null : null);
    if (encoded is! String || encoded.isEmpty) {
      throw const TtsException('empty_audio', 'MiMo 未返回朗读音频');
    }
    try {
      final bytes = base64Decode(encoded.replaceFirst(RegExp(r'^data:.*;base64,'), ''));
      if (bytes.isEmpty) {
        throw const TtsException('empty_audio', 'MiMo 返回空音频');
      }
      return bytes;
    } catch (e) {
      if (e is TtsException) rethrow;
      throw const TtsException('empty_audio', 'MiMo 音频数据解码失败');
    }
  }

  static String _bodyText(dynamic data) {
    if (data is String) return data;
    if (data is Map) {
      final error = data['error'];
      if (error is Map) {
        // MiMo 把音色清单放在 error.param（message 只有笼统的 Param Incorrect）。
        final parts = [
          error['message']?.toString() ?? '',
          error['param']?.toString() ?? '',
        ].where((e) => e.isNotEmpty);
        if (parts.isNotEmpty) return parts.join(' ');
      }
      if (data['message'] != null) return data['message'].toString();
      try {
        return jsonEncode(data);
      } catch (_) {}
    }
    return '$data';
  }

  /// 错误文案：截断 + 脱敏，禁止回显完整 Key。
  static String _friendlyError(Object? error, String apiKey) {
    if (error == null) return '未知错误';
    var text = error is DioException
        ? (error.type == DioExceptionType.connectionTimeout ||
                error.type == DioExceptionType.receiveTimeout ||
                error.type == DioExceptionType.sendTimeout
            ? '请求超时（30 秒）'
            : '网络不可用（${error.type.name}）')
        : error.toString().replaceFirst(RegExp(r'^TtsException\([^)]*\):\s*'), '');
    text = _truncate(text);
    if (apiKey.isNotEmpty) text = text.replaceAll(apiKey, '***');
    return text;
  }

  static String _truncate(String text) {
    final single = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return single.length <= 200 ? single : '${single.substring(0, 200)}…';
  }
}
