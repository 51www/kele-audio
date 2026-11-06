import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'tts_engine.dart';
import 'tts_settings_store.dart';

/// 自定义 HTTP 朗读引擎：URL 模板渲染 + 自定义请求头 + 音频流播放。
///
/// 模板占位符：`{text}`（URL 编码）、`{voice}`、`{rate}`。
class TtsHttpEngine implements TtsEngine {
  TtsHttpEngine({required this.templateProvider});

  /// 每次朗读前取当前模板（设置页改动即时生效）。
  final TtsHttpTemplate? Function() templateProvider;

  final Dio _dio = Dio();
  Player? _player;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<String>? _errorSub;
  Completer<void>? _pending;
  String? _lastError;
  TtsParams _params = const TtsParams();
  int _token = 0;

  @override
  String get id => 'http';

  void _ensurePlayer() {
    if (_player != null) return;
    MediaKit.ensureInitialized();
    final player = Player();
    _player = player;
    _completedSub = player.stream.completed.listen((done) {
      if (done) _pending?.complete();
    });
    _errorSub = player.stream.error.listen((message) {
      if (message.isEmpty) return;
      _lastError = message;
      _pending?.complete();
    });
  }

  String _renderUrl(TtsHttpTemplate template, String text) {
    final rate = ((_params.rate - 1.0) * 100).round();
    return template.url
        .replaceAll('{text}', Uri.encodeComponent(text))
        .replaceAll('{voice}', Uri.encodeComponent(_params.voice))
        .replaceAll('{rate}', '$rate');
  }

  @override
  Future<void> start(TtsParams params) async {
    _params = params;
    _ensurePlayer();
  }

  @override
  void prefetch(String text) {
    // HTTP 模板通常直接流式返回，预取会重复消耗服务端配额，不做预合成。
  }

  @override
  Future<void> speak(String text) async {
    final template = templateProvider();
    if (template == null || template.url.isEmpty) {
      throw const TtsException('config', '尚未配置 HTTP 朗读模板');
    }
    final url = _renderUrl(template, text);
    _ensurePlayer();
    final token = _token;
    _lastError = null;
    final completer = Completer<void>();
    _pending = completer;
    try {
      await _player!.open(
        Media(url, httpHeaders: template.headers.isEmpty ? null : template.headers),
        play: true,
      );
      if (token != _token) return;
      await completer.future.timeout(
        const Duration(seconds: 300),
        onTimeout: () {},
      );
      if (_lastError != null) {
        throw TtsException('playback_failed', _lastError!);
      }
    } on TtsException {
      rethrow;
    } catch (e) {
      throw TtsException('http_failed', '$e');
    } finally {
      if (identical(_pending, completer)) _pending = null;
    }
  }

  @override
  Future<void> stop() async {
    _token++;
    _pending?.complete();
    _pending = null;
    try {
      await _player?.stop();
    } catch (e) {
      debugPrint('[tts:http] stop 失败：$e');
    }
  }

  @override
  void resetCache() {}

  @override
  Future<void> testConnection() async {
    final template = templateProvider();
    if (template == null || template.url.isEmpty) {
      throw const TtsException('config', '尚未配置 HTTP 朗读模板');
    }
    final response = await _dio.get<List<int>>(
      _renderUrl(template, '你好'),
      options: Options(
        responseType: ResponseType.bytes,
        headers: template.headers.isEmpty ? null : template.headers,
        receiveTimeout: const Duration(seconds: 20),
        sendTimeout: const Duration(seconds: 10),
      ),
    );
    final bytes = response.data;
    if (bytes == null || bytes.isEmpty) {
      throw const TtsException('empty_audio', '模板返回空音频');
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _completedSub?.cancel();
    await _errorSub?.cancel();
    await _player?.dispose();
    _player = null;
  }
}
