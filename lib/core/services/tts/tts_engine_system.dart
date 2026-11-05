import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'tts_engine.dart';

/// 系统 TTS 引擎（Android TextToSpeech / iOS AVSpeechSynthesizer）。
class TtsSystemEngine implements TtsEngine {
  TtsSystemEngine();

  final FlutterTts _tts = FlutterTts();
  TtsParams _params = const TtsParams();
  bool _started = false;
  bool _speaking = false;

  /// 每次 speak/stop 自增，用于作废「切语速后重试」等异步尾动作。
  int _speakToken = 0;

  @override
  String get id => 'system';

  Future<void> _ensureStarted() async {
    if (_started) return;
    _started = true;
    try {
      final locale = _params.voice.isEmpty ? 'zh-CN' : _voiceLocale(_params.voice);
      final result = await _tts.setLanguage(locale);
      if (result == 0) {
        throw const TtsException(
          'system_unavailable',
          '系统朗读引擎不可用：设备缺少可用的语音合成引擎或中文语音包，'
          '请在系统设置中安装/启用语音引擎，或切换到 Edge 朗读',
        );
      }
      await _tts.awaitSpeakCompletion(true);
      _tts.setErrorHandler((message) {
        debugPrint('[tts:system] error: $message');
      });
    } catch (_) {
      // 允许下次重试（例如用户在系统设置里启用了朗读引擎）。
      _started = false;
      rethrow;
    }
  }

  /// App 统一语义：1.0x = 正常朗读速度。
  ///
  /// flutter_tts 的 Android 实现会把入参乘 2 再交给 `TextToSpeech.setSpeechRate`
  /// （即 flutter 0.5 → Android 1.0x），所以这里先算出目标 Android 倍率，再除以 2。
  /// 上限 1.8 防止最高档快到听不清；下限 0.4 让最低档明显慢于正常速度。
  static double androidRateFor(double appRate) => appRate.clamp(0.4, 1.8);

  static String _voiceLocale(String voice) {
    final match = RegExp(r'[a-z]{2}-[A-Z]{2}').firstMatch(voice);
    return match?.group(0) ?? 'zh-CN';
  }

  @override
  Future<void> start(TtsParams params) async {
    _params = params;
    await _ensureStarted();
    if (params.voice.isNotEmpty) {
      try {
        await _tts.setVoice({'name': params.voice, 'locale': _voiceLocale(params.voice)});
      } catch (e) {
        debugPrint('[tts:system] setVoice 失败（沿用系统默认）：$e');
      }
    }
    await _tts.setSpeechRate(androidRateFor(params.rate) / 2.0);
    await _tts.setPitch(params.pitch);
  }

  @override
  void prefetch(String text) {
    // 系统引擎由平台托管，无预合成能力。
  }

  @override
  Future<void> speak(String text) async {
    await _ensureStarted();
    final token = ++_speakToken;
    _speaking = true;
    try {
      var result = await _tts.speak(text);
      if (result == 0) {
        // 切语速/跳段后紧接着 speak，部分系统引擎（OPPO）会短暂返回 0：
        // 等引擎从 stop 状态恢复后重试一次，不把它当成「引擎不可用」。
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (token != _speakToken) return; // 已被 stop/pause 或新一段取代
        result = await _tts.speak(text);
      }
      if (result == 0) {
        throw const TtsException('speak_failed', '系统朗读暂时无法合成');
      }
    } on TtsException {
      rethrow;
    } catch (e) {
      throw TtsException(
        'speak_failed',
        '系统朗读失败：${_cleanError(e)}',
      );
    } finally {
      if (token == _speakToken) _speaking = false;
    }
  }

  static String _cleanError(Object e) {
    final text = e.toString();
    return text.replaceFirst(RegExp(r'^[A-Za-z]+Exception\([^)]*\):\s*'), '');
  }

  @override
  Future<void> stop() async {
    _speakToken++;
    _speaking = false;
    await _tts.stop();
    // 部分系统引擎 stop 返回后仍短暂占用，立即 speak 会返回 0；留一个恢复窗口。
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }

  /// 平台可用中文音色（设置页选择系统音色用）。
  Future<List<TtsVoice>> listVoices() async {
    try {
      final raw = await _tts.getVoices;
      final list = <TtsVoice>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is! Map) continue;
          final locale = item['locale']?.toString() ?? '';
          if (!locale.toLowerCase().startsWith('zh')) continue;
          final name = item['name']?.toString() ?? '';
          if (name.isEmpty) continue;
          list.add(TtsVoice(id: name, name: name, locale: locale));
        }
      }
      return list;
    } catch (e) {
      debugPrint('[tts:system] getVoices 失败：$e');
      return const [];
    }
  }

  @override
  Future<void> testConnection() async {
    await _ensureStarted();
    if (!_speaking) {
      throw const TtsException('unsupported', '系统引擎不需要联网自检');
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
