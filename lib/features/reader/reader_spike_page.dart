import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/services/reader/web_capture.dart';
import 'spike/edge_tts_spike.dart';

/// M9.0 技术验证 spike 页（docs/reader-milestones.md M9.0，Android 真机专用）。
///
/// 验证点：
/// 1. WebView 经 WebViewAssetLoader（https origin）加载 assets/reader/index.html
///    + foliate-js（ES module 相对引用）；
/// 2. 样例 EPUB 分页渲染 / 手势翻页 / 跳章 / onRelocated 回调到达 Dart；
/// 3. Headless WebView + Readability.js 正文提取；
/// 4. Edge TTS（自建客户端 v2 认证）合成 mp3 + media_kit 独立 Player 播放。
class ReaderSpikePage extends StatefulWidget {
  const ReaderSpikePage({super.key});

  @override
  State<ReaderSpikePage> createState() => _ReaderSpikePageState();
}

class _ReaderSpikePageState extends State<ReaderSpikePage> {
  /// WebViewAssetLoader 的 https 域名（androidx.webkit 默认域）。
  static const _assetDomain = 'appassets.androidplatform.net';

  InAppWebViewController? _controller;
  final Player _ttsPlayer = Player();
  final TextEditingController _urlField =
      TextEditingController(text: 'https://example.com');

  final List<String> _messages = [];
  String _ttsStatus = '未开始';
  String _captureStatus = '未开始';

  @override
  void dispose() {
    _ttsPlayer.dispose();
    _urlField.dispose();
    super.dispose();
  }

  void _log(String text) {
    final ts = DateTime.now().toIso8601String().substring(11, 19);
    if (mounted) {
      setState(() {
        _messages.insert(0, '[$ts] $text');
        if (_messages.length > 10) _messages.removeLast();
      });
    }
    debugPrint('[spike] $text');
  }

  Future<void> _loadSampleBook() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final data = await rootBundle.load('assets/reader/sample/sample.epub');
      final b64 = base64Encode(data.buffer.asUint8List());
      _log('Dart→JS loadBook(${data.lengthInBytes} bytes)');
      final result = await controller.evaluateJavascript(
        source: "window.spike.loadBook('$b64')",
      );
      _log('loadBook 返回: $result');
    } catch (e) {
      _log('loadBook 失败: $e');
    }
  }

  Future<void> _eval(String source, String label) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final result = await controller.evaluateJavascript(source: source);
      _log('$label → $result');
    } catch (e) {
      _log('$label 失败: $e');
    }
  }

  Future<void> _runTtsSpike() async {
    setState(() => _ttsStatus = '合成中…（Edge TTS WebSocket v2）');
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/spike_tts.mp3';
      final out = await synthesizeEdgeTts(
        '可乐听书，M九点零技术验证。日出江花红胜火，春来江水绿如蓝。能不忆江南？',
        path,
      );
      setState(() => _ttsStatus = '合成完成，media_kit 独立实例播放中…');
      await _ttsPlayer.open(Media(out));
      _log('TTS 产物: $out');
    } catch (e) {
      setState(() => _ttsStatus = '失败: $e');
      _log('TTS 失败: $e');
    }
  }

  Future<void> _runCapture() async {
    final url = _urlField.text.trim();
    if (url.isEmpty) {
      setState(() => _captureStatus = '请先输入文章 URL');
      return;
    }
    setState(() => _captureStatus = '抓取中…');
    try {
      final result = await WebArticleCapture.capture(url);
      setState(() => _captureStatus =
          '成功: 「${result.title}」 正文 ${result.textLength} 字\n开头: ${result.excerpt}…');
    } on WebCaptureException catch (e) {
      setState(() => _captureStatus = '失败(${e.kind}): ${e.message}');
    } catch (e) {
      setState(() => _captureStatus = '失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('M9.0 技术验证 Spike'),
        actions: [
          IconButton(
            tooltip: '打开样例书',
            icon: const Icon(Icons.menu_book_outlined),
            onPressed: _loadSampleBook,
          ),
        ],
      ),
      body: Column(
        children: [
          // ---- ① WebView + foliate-js ----
          Expanded(
            flex: 5,
            child: InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri(
                    // AssetsPathHandler 注册前缀为 /assets/，其后是 APK 内的
                    // flutter_assets 目录，再后才是 Flutter asset key（assets/reader/…）。
                    'https://$_assetDomain/assets/flutter_assets/assets/reader/index.html'),
              ),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                // WebViewAssetLoader：assets 以 https origin 提供，
                // ES module 相对引用不被 CORS 拦截（spike 定版主方案）
                webViewAssetLoader: WebViewAssetLoader(
                  domain: _assetDomain,
                  pathHandlers: [AssetsPathHandler(path: '/assets/')],
                ),
              ),
              onWebViewCreated: (controller) {
                _controller = controller;
                controller.addJavaScriptHandler(
                  handlerName: 'spikeMessage',
                  callback: (args) {
                    if (args.isNotEmpty && args.first is Map) {
                      final msg = args.first as Map;
                      _log('JS→Dart ${msg['name']}: ${msg['payload']}');
                    }
                    return null;
                  },
                );
                _log('WebView created');
              },
              onLoadStop: (controller, url) {
                _log('onLoadStop: $url');
              },
              onConsoleMessage: (controller, message) {
                if (message.message.startsWith('SPIKE_MSG')) {
                  _log('console ${message.message}');
                }
              },
            ),
          ),
          // ---- 控制与结果面板 ----
          Expanded(
            flex: 4,
            child: _BottomPanel(theme: theme, state: this),
          ),
        ],
      ),
    );
  }
}

class _BottomPanel extends StatelessWidget {
  const _BottomPanel({required this.theme, required this.state});

  final ThemeData theme;
  final _ReaderSpikePageState state;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: DefaultTextStyle(
        style: theme.textTheme.bodySmall!,
        child: ListView(
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                FilledButton.tonal(
                  onPressed: state._loadSampleBook,
                  child: const Text('打开样例书'),
                ),
                OutlinedButton(
                  onPressed: () => state._eval('window.spike.prev()', '上一页'),
                  child: const Text('上一页'),
                ),
                OutlinedButton(
                  onPressed: () => state._eval('window.spike.next()', '下一页'),
                  child: const Text('下一页'),
                ),
                OutlinedButton(
                  onPressed: () =>
                      state._eval('window.spike.goToChapter(2)', '跳到第3章'),
                  child: const Text('跳到第3章'),
                ),
                OutlinedButton(
                  onPressed: () => state._eval(
                      "window.spike.setFlow('paginated')", '翻页模式'),
                  child: const Text('翻页模式'),
                ),
                OutlinedButton(
                  onPressed: () => state._eval(
                      "window.spike.setFlow('scrolled')", '滚动模式'),
                  child: const Text('滚动模式'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // ---- JS→Dart 消息日志 ----
            Container(
              key: const Key('spike-log'),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('JS ↔ Dart 消息（最新在上）',
                      style: theme.textTheme.labelSmall),
                  const SizedBox(height: 4),
                  for (final m in state._messages.take(6))
                    Text(m, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // ---- TTS ----
            Row(
              children: [
                FilledButton.tonal(
                  onPressed: state._runTtsSpike,
                  child: const Text('Edge TTS → media_kit 播放'),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(state._ttsStatus)),
              ],
            ),
            // ---- 抓取 ----
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 280,
                  child: TextField(
                    controller: state._urlField,
                    style: theme.textTheme.bodySmall,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      labelText: '文章 URL（任意网页）',
                      hintText: 'https://example.com/article/…',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: state._runCapture,
                  child: const Text('Headless 抓取正文'),
                ),
              ],
            ),
            Text(state._captureStatus),
          ],
        ),
      ),
    );
  }
}
