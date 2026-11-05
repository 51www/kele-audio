import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'reader_typography.dart';

/// 一本书在 WebView 内解析出的元数据（`onBookMeta`）。
class ReaderBookMeta {
  const ReaderBookMeta({
    required this.title,
    required this.author,
    required this.chapterCount,
  });

  final String title;
  final String author;
  final int chapterCount;
}

/// 阅读位置（`onRelocated`）。
class ReaderLocation {
  const ReaderLocation({
    required this.chapterIndex,
    required this.fraction,
    required this.cfi,
    this.page,
    this.pageCount,
  });

  final int chapterIndex;
  final double fraction;
  final String cfi;

  /// 全书当前页码 / 总页数（JS 侧按字数估算，拿不到时为 null）。
  final int? page;
  final int? pageCount;
}

/// 目录项（`onToc`）。
class ReaderTocItem {
  const ReaderTocItem({
    required this.index,
    required this.label,
    required this.href,
  });

  final int index;
  final String label;
  final String href;
}

/// 一条 JS→Dart 桥消息。
class ReaderBridgeMessage {
  const ReaderBridgeMessage({required this.name, required this.payload});

  final String name;
  final Map<String, dynamic> payload;

  /// 解析 `{name, payload}`；结构不合法返回 null（JS 侧异常不应带崩页面）。
  static ReaderBridgeMessage? parse(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name']?.toString();
    if (name == null || name.isEmpty) return null;
    final payload = raw['payload'];
    return ReaderBridgeMessage(
      name: name,
      payload: payload is Map
          ? Map<String, dynamic>.from(payload)
          : const <String, dynamic>{},
    );
  }
}

/// 注入给 WebView 的排版 / 主题载荷（`setStyle`）。
class ReaderStylePayload {
  const ReaderStylePayload({
    required this.typography,
    required this.background,
    required this.foreground,
    required this.muted,
    required this.accent,
    required this.hairline,
    required this.isDark,
  });

  final ReaderTypography typography;
  final Color background;
  final Color foreground;
  final Color muted;
  final Color accent;
  final Color hairline;
  final bool isDark;

  /// `#AARRGGBB` → `#RRGGBB`（css 不接受 8 位写法时更稳妥）。
  static String _hex(Color color) {
    final argb = color.toARGB32();
    final rgb = argb & 0x00FFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0')}';
  }

  Map<String, dynamic> toJson() => {
    'fontSize': typography.fontSize,
    'lineHeight': typography.lineHeight,
    'margin': typography.margin,
    'weight': typography.weight,
    'mode': typography.flow.jsValue,
    'colors': {
      'bg': _hex(background),
      'fg': _hex(foreground),
      'muted': _hex(muted),
      'accent': _hex(accent),
      'line': _hex(hairline),
    },
    'dark': isDark,
  };
}

/// WebView ↔ Dart 桥协议封装（docs/reader-design.md §4.2）。
///
/// 页面层只通过本类读写阅读会话，禁止在 UI 代码里直接调用 webview API。
class ReaderBridge {
  ReaderBridge({
    this.onReady,
    this.onBookMeta,
    this.onRelocated,
    this.onToc,
    this.onTapCenter,
    this.onError,
    this.log,
  });

  static const handlerName = 'readerMessage';

  /// 每次 evaluateJavascript 传输的 base64 长度（4 的倍数），
  /// 避免单条 JS 表达式过大导致 Android WebView 卡顿/失败。
  static const int chunkSize = 200000;

  final VoidCallback? onReady;
  final ValueChanged<ReaderBookMeta>? onBookMeta;
  final ValueChanged<ReaderLocation>? onRelocated;
  final ValueChanged<List<ReaderTocItem>>? onToc;
  final VoidCallback? onTapCenter;
  final ValueChanged<String>? onError;
  final void Function(String message)? log;

  InAppWebViewController? _controller;
  final List<String> _pending = [];
  bool _ready = false;
  Completer<bool>? _loadCompleter;

  bool get isReady => _ready;

  /// 必须在 `onWebViewCreated` 内调用（注册 JS handler + 保存 controller）。
  void attach(InAppWebViewController controller) {
    _controller = controller;
    controller.addJavaScriptHandler(
      handlerName: handlerName,
      callback: _handle,
    );
  }

  void _handle(List<dynamic> args) {
    final message = args.isEmpty
        ? null
        : ReaderBridgeMessage.parse(args.first);
    if (message == null) return;
    final p = message.payload;
    switch (message.name) {
      case 'onReady':
        _ready = true;
        log?.call('bridge ready');
        _flush();
        onReady?.call();
      case 'onBookMeta':
        onBookMeta?.call(
          ReaderBookMeta(
            title: p['title']?.toString() ?? '',
            author: p['author']?.toString() ?? '',
            chapterCount: (p['chapterCount'] as num?)?.toInt() ?? 0,
          ),
        );
      case 'onLoadComplete':
        if (_loadCompleter?.isCompleted == false) {
          _loadCompleter!.complete(true);
        }
      case 'onRelocated':
        onRelocated?.call(
          ReaderLocation(
            chapterIndex: (p['index'] as num?)?.toInt() ?? 0,
            fraction: (p['fraction'] as num?)?.toDouble() ?? 0,
            cfi: p['cfi']?.toString() ?? '',
            page: (p['page'] as num?)?.toInt(),
            pageCount: (p['pageCount'] as num?)?.toInt(),
          ),
        );
      case 'onToc':
        final raw = p['items'];
        final items = <ReaderTocItem>[];
        if (raw is List) {
          for (var i = 0; i < raw.length; i++) {
            final item = raw[i];
            if (item is! Map) continue;
            items.add(
              ReaderTocItem(
                index: (item['index'] as num?)?.toInt() ?? i,
                label: item['label']?.toString() ?? '第${i + 1}章',
                href: item['href']?.toString() ?? '',
              ),
            );
          }
        }
        onToc?.call(items);
      case 'onTapCenter':
        onTapCenter?.call();
      case 'onError':
        onError?.call(p['message']?.toString() ?? '未知错误');
        if (_loadCompleter?.isCompleted == false) {
          _loadCompleter!.complete(false);
        }
      default:
        log?.call('未处理消息 ${message.name}');
    }
  }

  /// 打开书籍：分片传 base64，避免单条 JS 表达式过大。
  ///
  /// 完成信号走 `onLoadComplete` / `onError` 消息（`evaluateJavascript`
  /// 对 async 函数只会拿到 Promise，不能靠返回值判断）。
  Future<bool> loadBook({
    required String fileName,
    required Uint8List bytes,
  }) async {
    if (_controller == null) return false;
    final completer = Completer<bool>();
    _loadCompleter = completer;
    try {
      final b64 = base64Encode(bytes);
      _send('window.reader.beginLoad(${b64.length})');
      for (var i = 0; i < b64.length; i += chunkSize) {
        final end = (i + chunkSize > b64.length) ? b64.length : i + chunkSize;
        final ok = await _eval(
          "window.reader.pushChunk('${b64.substring(i, end)}')",
        );
        if (ok == null) return false;
      }
      await _eval('window.reader.finishLoad(${jsonEncode(fileName)})');
      return await completer.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => false,
      );
    } finally {
      if (identical(_loadCompleter, completer)) _loadCompleter = null;
    }
  }

  /// 定位：优先 CFI（章内精确位置），否则章节索引 + 章内比例。
  Future<void> openAt({
    int chapterIndex = 0,
    double fraction = 0,
    String? cfi,
  }) {
    final payload = <String, dynamic>{
      'chapterIndex': chapterIndex,
      'fraction': fraction,
      if (cfi != null && cfi.isNotEmpty) 'cfi': cfi,
    };
    return _send('window.reader.openAt(${jsonEncode(payload)})');
  }

  /// 排版 / 主题注入。
  Future<void> setStyle(ReaderStylePayload style) {
    return _send('window.reader.setStyle(${jsonEncode(style.toJson())})');
  }

  Future<void> requestToc() => _send('window.reader.requestToc()');

  Future<void> goToChapter(int index) =>
      _send('window.reader.goToChapter($index)');

  Future<void> goToHref(String href) =>
      _send('window.reader.goToHref(${jsonEncode(href)})');

  Future<void> next() => _send('window.reader.next()');

  Future<void> prev() => _send('window.reader.prev()');

  // ---- M9.3 TTS：段落提取 / 高亮跟随 / 位置查询 -------------------------

  /// 当前渲染章节索引（未就绪返回 0）。
  Future<int> currentChapter() async {
    final raw = await _eval('window.reader.currentChapterIndex()');
    return _asInt(raw);
  }

  Future<bool> isChapterReady(int index) async {
    final raw = await _eval('window.reader.isChapterReady($index)');
    return raw == true || raw?.toString() == 'true';
  }

  /// 提取当前章节正文段落（纯文本数组，同步 JS 调用）。
  Future<List<String>> extractParagraphs() async {
    final raw = await _eval('window.reader.extractParagraphs()');
    final decoded = raw is String ? _tryDecode(raw) : raw;
    if (decoded is List) {
      return [
        for (final item in decoded)
          if (item != null && item.toString().trim().isNotEmpty)
            item.toString(),
      ];
    }
    return const [];
  }

  Future<void> highlightParagraph(int index) =>
      _send('window.reader.highlightParagraph($index)');

  Future<void> clearHighlight() => _send('window.reader.clearHighlight()');

  /// 当前可见区域所在段落；取不到返回 0。
  Future<int> visibleParagraphIndex() async {
    final raw = await _eval('window.reader.visibleParagraphIndex()');
    return _asInt(raw);
  }

  static int _asInt(dynamic raw) {
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }

  static dynamic _tryDecode(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _pending.clear();
    _controller = null;
  }

  /// 未就绪时排队，就绪后按序补发。
  Future<void> _send(String js) async {
    if (_ready && _controller != null) {
      await _controller!.evaluateJavascript(source: js);
    } else {
      _pending.add(js);
    }
  }

  Future<dynamic> _eval(String js) async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      return await controller.evaluateJavascript(source: js);
    } catch (e) {
      log?.call('JS 执行失败：$e');
      return null;
    }
  }

  void _flush() {
    final controller = _controller;
    if (controller == null) return;
    for (final js in _pending) {
      controller.evaluateJavascript(source: js);
    }
    _pending.clear();
  }
}
