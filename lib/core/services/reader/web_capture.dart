import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 通用网页正文抓取。
///
/// 流程：
/// 1. **静态 HTML 直抓**：HTTP GET（跟随重定向、限制大小与编码）→
///    在隐藏 WebView 中以 `initialData` 载入 → Readability/启发式提取；
/// 2. 静态结果不足时回退 **WebView 实页渲染**：等待 DOM 稳定、点击
///    「展开全文」一类公开按钮，再注入 Readability 与文本密度兜底；
/// 3. 识别登录墙 / 验证码 / 折叠内容 / 非 HTML 内容，交给上层给出提示。
///
/// HeadlessInAppWebView 仅 Android/桌面可用，Web 端返回明确的不可用错误。
class WebArticleCapture {
  WebArticleCapture._();

  static const _timeout = Duration(seconds: 30);
  static const _staticTimeout = Duration(seconds: 12);

  /// 静态 HTML 提取的可信下限；低于该值说明正文大概率由 JS 渲染，回退实页。
  static const int staticMinTextLength = 600;

  /// 最终入库的正文下限（少于 200 字不视为成功）。
  static const int minTextLength = 200;

  static const _readabilityAsset = 'assets/reader/readability/Readability.js';
  static const _extractAsset = 'assets/reader/extract.js';

  static const _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  static final Dio _http = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 12),
      followRedirects: true,
      maxRedirects: 6,
      responseType: ResponseType.bytes,
      validateStatus: (_) => true,
      headers: const {
        'User-Agent': _desktopUserAgent,
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      },
    ),
  );

  /// 抓取并提取正文。
  ///
  /// 成功返回 [WebArticleResult]；失败抛 [WebCaptureException]，
  /// [WebCaptureException.kind] 区分 网络 / 超时 / 正文为空 / 需登录受限 /
  /// 内容类型不支持。
  static Future<WebArticleResult> capture(String url) async {
    if (kIsWeb) {
      throw const WebCaptureException(
        kind: WebCaptureError.unsupported,
        message: 'Headless WebView 在 Web 端不可用',
      );
    }

    final readabilityJs = await rootBundle.loadString(_readabilityAsset);
    final extractJs = await rootBundle.loadString(_extractAsset);

    // URL 路径就直接是文件下载时，无需再启动 WebView。
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    const binaryExtensions = [
      '.pdf',
      '.mp4',
      '.mov',
      '.avi',
      '.mp3',
      '.wav',
      '.zip',
      '.rar',
      '.doc',
      '.docx',
      '.ppt',
      '.pptx',
      '.xls',
      '.xlsx',
    ];
    if (binaryExtensions.any((ext) => path.endsWith(ext))) {
      throw const WebCaptureException(
        kind: WebCaptureError.unsupported,
        message: '该链接指向文件（PDF/视频/压缩包等），不是可播报的网页文章。',
      );
    }

    var httpStatus = 0;
    final page = await _fetchStatic(url);
    if (page != null) {
      httpStatus = page.status;
      if (page.html.isNotEmpty && page.status > 0 && page.status < 400) {
        try {
          final result = await _extractFromHtml(
            html: page.html,
            baseUrl: page.finalUrl,
            readabilityJs: readabilityJs,
            extractJs: extractJs,
            httpStatus: page.status,
            mode: 'static',
          );
          if (result.textLength >= staticMinTextLength) return result;
        } on WebCaptureException {
          // 静态 HTML 提取失败（编码/JS 渲染/登录墙），统一回退实页。
        }
      }
    }

    return _captureLive(
      url: url,
      readabilityJs: readabilityJs,
      extractJs: extractJs,
      httpStatusHint: httpStatus,
    );
  }

  // ---- 静态 HTML 直抓 -----------------------------------------------------

  /// 拉取 HTML 原文；无法直抓时返回 null（由 WebView 再判断）。
  ///
  /// 仅对明确非 HTML 的内容类型直接报错（PDF/视频/图片/压缩包等），
  /// 其余失败都留给实页渲染，避免误杀需要 JS 或鉴权的正常页面。
  static Future<_StaticPage?> _fetchStatic(String url) async {
    try {
      final response = await _http.get<List<int>>(url);
      final status = response.statusCode ?? 0;
      final contentType =
          response.headers.value(Headers.contentTypeHeader)?.toLowerCase() ??
          '';
      final finalUrl = response.realUri.toString();
      final bytes = response.data;

      if (_isBinaryContentType(contentType)) {
        throw WebCaptureException(
          kind: WebCaptureError.unsupported,
          message:
              '该链接返回 ${_mimeOf(contentType)} 内容，不是可播报的网页文章（PDF/视频/图片等请勿用本功能导入）',
        );
      }
      if (bytes == null || bytes.isEmpty) {
        return _StaticPage(status: status, finalUrl: finalUrl, html: '');
      }
      if (!_looksLikeHtml(contentType, bytes)) {
        return _StaticPage(status: status, finalUrl: finalUrl, html: '');
      }
      // 非 UTF-8 编码交给 WebView（它能按页面声明正确解码，避免乱码入库）。
      final charset = _declaredCharset(contentType, bytes);
      if (charset != null && !_isUtf8Charset(charset)) {
        return _StaticPage(status: status, finalUrl: finalUrl, html: '');
      }
      if (bytes.length > 3 * 1024 * 1024) {
        return _StaticPage(status: status, finalUrl: finalUrl, html: '');
      }
      return _StaticPage(
        status: status,
        finalUrl: finalUrl,
        html: utf8.decode(bytes, allowMalformed: true),
      );
    } on WebCaptureException {
      rethrow;
    } catch (_) {
      // 网络超时、证书错误、反爬拒绝等：不在此处下结论。
      return null;
    }
  }

  static bool _isBinaryContentType(String contentType) {
    final mime = _mimeOf(contentType);
    if (mime.isEmpty) return false;
    return mime.startsWith('application/pdf') ||
        mime.startsWith('video/') ||
        mime.startsWith('audio/') ||
        mime.startsWith('image/') ||
        mime == 'application/zip' ||
        mime == 'application/x-zip-compressed' ||
        mime == 'application/msword' ||
        mime.startsWith('application/vnd.ms-') ||
        mime.startsWith('application/vnd.openxmlformats') ||
        mime == 'application/json';
  }

  static String _mimeOf(String contentType) =>
      contentType.split(';').first.trim().toLowerCase();

  static bool _looksLikeHtml(String contentType, List<int> bytes) {
    final mime = _mimeOf(contentType);
    if (mime.contains('html') || mime.contains('xml')) return true;
    if (mime.isNotEmpty && !mime.startsWith('text/')) return false;
    final head = utf8
        .decode(bytes.take(512).toList(), allowMalformed: true)
        .trimLeft()
        .toLowerCase();
    return head.startsWith('<!doctype html') ||
        head.startsWith('<html') ||
        head.contains('<head') ||
        head.contains('<body');
  }

  static String? _declaredCharset(String contentType, List<int> bytes) {
    final header = RegExp(
      r'charset\s*=\s*"?([\w-]+)',
      caseSensitive: false,
    ).firstMatch(contentType);
    if (header != null) return header.group(1)?.toLowerCase();
    final head = utf8
        .decode(bytes.take(4096).toList(), allowMalformed: true)
        .toLowerCase();
    final meta = RegExp(
      r"""charset\s*=\s*["']?([\w-]+)""",
      caseSensitive: false,
    ).firstMatch(head);
    return meta?.group(1)?.toLowerCase();
  }

  static bool _isUtf8Charset(String charset) {
    final normalized = charset.replaceAll('-', '').replaceAll('_', '');
    return normalized == 'utf8' ||
        normalized == 'usascii' ||
        normalized == 'ascii';
  }

  /// 在隐藏 WebView 中以静态 HTML 载入并提取（不执行站点脚本）。
  static Future<WebArticleResult> _extractFromHtml({
    required String html,
    required String baseUrl,
    required String readabilityJs,
    required String extractJs,
    required int httpStatus,
    required String mode,
  }) async {
    final completer = Completer<String>();
    HeadlessInAppWebView? headless;
    var status = httpStatus;
    var started = false;

    Future<void> finish(String raw) async {
      if (!completer.isCompleted) completer.complete(raw);
      try {
        await headless?.dispose();
      } catch (_) {}
    }

    Future<void> extractOnce(InAppWebViewController controller) async {
      if (started) return;
      started = true;
      try {
        await controller.evaluateJavascript(source: extractJs);
        final raw = await controller.evaluateJavascript(
          source: 'extractArticle()',
        );
        await finish(raw?.toString() ?? 'null');
      } catch (e) {
        await finish(
          jsonEncode({
            'ok': false,
            'error': 'INJECT: $e',
            'httpStatus': status,
          }),
        );
      }
    }

    headless = HeadlessInAppWebView(
      initialData: InAppWebViewInitialData(
        data: html,
        baseUrl: WebUri(baseUrl),
        mimeType: 'text/html',
        encoding: 'utf-8',
        historyUrl: WebUri(baseUrl),
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
      ),
      onDOMContentLoaded: (controller, uri) => extractOnce(controller),
      onLoadStop: (controller, uri) => extractOnce(controller),
      onReceivedHttpError: (controller, request, response) {
        if (request.isForMainFrame == true) {
          status = response.statusCode ?? status;
        }
      },
    );

    try {
      await headless.run();
      final raw = await completer.future.timeout(
        _staticTimeout,
        onTimeout: () => jsonEncode({'ok': false, 'error': 'TIMEOUT'}),
      );
      return _decodeRaw(
        raw,
        fallbackUrl: baseUrl,
        mode: mode,
        httpStatus: status,
      );
    } finally {
      try {
        await headless.dispose();
      } catch (_) {}
    }
  }

  // ---- WebView 实页渲染 ---------------------------------------------------

  static Future<WebArticleResult> _captureLive({
    required String url,
    required String readabilityJs,
    required String extractJs,
    required int httpStatusHint,
  }) async {
    final completer = Completer<String>();
    HeadlessInAppWebView? headless;
    var status = httpStatusHint;

    Future<void> finish(String raw) async {
      if (!completer.isCompleted) completer.complete(raw);
      try {
        await headless?.dispose();
      } catch (_) {}
    }

    headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
      ),
      onLoadStop: (controller, uri) async {
        try {
          await _waitForDomStable(controller);
          await controller.evaluateJavascript(source: extractJs);
          await controller.evaluateJavascript(
            source: 'expandCollapsedContent()',
          );
          await Future<void>.delayed(const Duration(milliseconds: 600));
          await controller.evaluateJavascript(source: readabilityJs);
          final raw = await controller.evaluateJavascript(
            source: 'extractArticle()',
          );
          await finish(raw?.toString() ?? 'null');
        } catch (e) {
          await finish(
            jsonEncode({
              'ok': false,
              'error': 'INJECT: $e',
              'httpStatus': status,
            }),
          );
        }
      },
      onReceivedError: (controller, request, error) async {
        if (request.isForMainFrame != true) return;
        // 4xx/5xx 的错误页仍可能带可读正文，交由 _failure 按状态码映射；
        // 其余网络错误立即结束，避免长时间挂起。
        await finish(
          jsonEncode({
            'ok': false,
            'error': status >= 400
                ? 'HTTP_STATUS'
                : 'NET: ${error.description}',
            'httpStatus': status,
          }),
        );
      },
      onReceivedHttpError: (controller, request, response) {
        // 不立即失败：部分站点会返回 4xx 同时仍带可读正文（或可被脚本渲染）。
        if (request.isForMainFrame == true) {
          status = response.statusCode ?? status;
        }
      },
    );

    try {
      await headless.run();
      final raw = await completer.future.timeout(
        _timeout,
        onTimeout: () => jsonEncode({'ok': false, 'error': 'TIMEOUT'}),
      );
      return _decodeRaw(
        raw,
        fallbackUrl: url,
        mode: 'webview',
        httpStatus: status,
      );
    } finally {
      try {
        await headless.dispose();
      } catch (_) {}
    }
  }

  /// 轮询正文长度直到稳定（最多约 9 秒），避免 onLoadStop 早于脚本渲染。
  static Future<void> _waitForDomStable(
    InAppWebViewController controller,
  ) async {
    var last = -1;
    var stableRounds = 0;
    for (var i = 0; i < 18; i++) {
      final raw = await controller.evaluateJavascript(
        source: 'document.body ? document.body.innerText.length : 0',
      );
      final length = raw is num ? raw.toInt() : int.tryParse('$raw') ?? 0;
      if (length > 300 && length == last) {
        stableRounds++;
      } else {
        stableRounds = 0;
      }
      last = length;
      if (length > 300 && stableRounds >= 2) return;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  // ---- 结果与错误映射 -----------------------------------------------------

  static WebArticleResult _decodeRaw(
    String raw, {
    required String fallbackUrl,
    required String mode,
    required int httpStatus,
  }) {
    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      throw WebCaptureException(
        kind: WebCaptureError.network,
        message: '页面提取结果无法解析（$raw）',
      );
    }

    final blocked = decoded['blocked']?.toString() ?? '';
    final truncated = decoded['truncated'] == true;
    final url = decoded['url']?.toString() ?? '';

    if (decoded['ok'] != true) {
      throw _failure(
        decoded['error']?.toString() ?? 'UNKNOWN',
        blocked: blocked,
        httpStatus: httpStatus,
      );
    }

    final textLength = (decoded['textLength'] as num?)?.toInt() ?? 0;
    if (textLength < minTextLength) {
      throw _failure('EMPTY', blocked: blocked, httpStatus: httpStatus);
    }
    // 登录墙/验证码页通常只剩少量提示文字，直接判为受限，不生成半篇书。
    if (blocked.isNotEmpty && textLength < 2000) {
      throw WebCaptureException(
        kind: WebCaptureError.blocked,
        message:
            '页面需要登录或触发了访问限制（$blocked），未能获取完整正文。'
            '请在浏览器中打开并登录后重试，或改用可公开访问的链接。',
      );
    }

    // 通用列表页判定：段落多但都很短、几乎没有长段落，通常是首页/频道/标签页。
    final paragraphs = (decoded['paragraphs'] as num?)?.toInt() ?? 0;
    final longParagraphs = (decoded['longParagraphs'] as num?)?.toInt() ?? 0;
    final looksLikeIndexPage =
        (textLength < 1200 && paragraphs >= 15 && longParagraphs < 4) ||
        (textLength < 800 && paragraphs >= 6 && longParagraphs == 0);
    if (looksLikeIndexPage) {
      throw const WebCaptureException(
        kind: WebCaptureError.empty,
        message:
            '未提取到正文：该页面更像首页/列表/推荐页（段落短、链接多），'
            '请粘贴具体文章详情页链接。',
      );
    }

    String? notice;
    if (truncated) {
      notice = '页面含有「展开全文」等内容，正文可能不完整';
    } else if (blocked.isNotEmpty) {
      notice = '页面提示「$blocked」，已提取可见部分，正文可能不完整';
    }

    return WebArticleResult(
      title: decoded['title']?.toString() ?? '',
      byline: decoded['byline']?.toString() ?? '',
      textLength: textLength,
      excerpt: decoded['excerpt']?.toString() ?? '',
      contentHtml: decoded['content']?.toString() ?? '',
      finalUrl: url.trim().isEmpty ? fallbackUrl : url.trim(),
      mode: mode,
      notice: notice,
      publishedTime: decoded['publishedTime']?.toString() ?? '',
      blockedReason: blocked,
      truncated: truncated,
    );
  }

  static WebCaptureException _failure(
    String error, {
    required String blocked,
    required int httpStatus,
  }) {
    if (blocked.isNotEmpty) {
      return WebCaptureException(
        kind: WebCaptureError.blocked,
        message:
            '页面需要登录或触发了访问限制（$blocked），未能获取正文。'
            '请在浏览器中打开并登录后重试，或改用可公开访问的链接。',
      );
    }
    if (httpStatus == 401 ||
        httpStatus == 403 ||
        httpStatus == 407 ||
        httpStatus == 429 ||
        httpStatus == 451) {
      return WebCaptureException(
        kind: WebCaptureError.blocked,
        message: '站点返回 HTTP $httpStatus（需要登录或拒绝访问），无法抓取正文。',
      );
    }
    if (httpStatus == 404 || httpStatus == 410) {
      return WebCaptureException(
        kind: WebCaptureError.empty,
        message: '页面不存在或已删除（HTTP $httpStatus）。',
      );
    }
    if (httpStatus >= 500) {
      return WebCaptureException(
        kind: WebCaptureError.network,
        message: '站点服务器异常（HTTP $httpStatus），请稍后重试。',
      );
    }
    if (error == 'TIMEOUT') {
      return const WebCaptureException(
        kind: WebCaptureError.timeout,
        message: '页面加载超时：正文可能依赖脚本渲染或网络过慢，请稍后重试。',
      );
    }
    if (error == 'EMPTY') {
      return const WebCaptureException(
        kind: WebCaptureError.empty,
        message:
            '未提取到足够正文（少于 200 字）：可能是首页/列表/视频等非文章页，'
            '或正文需要登录、交互后才会出现。',
      );
    }
    if (error.startsWith('NET:')) {
      return WebCaptureException(
        kind: WebCaptureError.network,
        message: '网络请求失败：${error.substring(4).trim()}',
      );
    }
    return WebCaptureException(
      kind: WebCaptureError.network,
      message: '正文提取失败：$error',
    );
  }
}

class _StaticPage {
  const _StaticPage({
    required this.status,
    required this.finalUrl,
    required this.html,
  });

  final int status;
  final String finalUrl;
  final String html;
}

class WebArticleResult {
  const WebArticleResult({
    required this.title,
    required this.byline,
    required this.textLength,
    required this.excerpt,
    this.contentHtml = '',
    this.finalUrl = '',
    this.mode = '',
    this.notice,
    this.publishedTime = '',
    this.blockedReason = '',
    this.truncated = false,
  });

  final String title;
  final String byline;
  final int textLength;
  final String excerpt;

  /// Readability/启发式提取的正文 HTML（保留图片等标签）。
  final String contentHtml;

  /// 跳转后的最终 URL（写回 originUrl 供「重新抓取」）。
  final String finalUrl;

  /// 提取路径：`static`（HTTP 原文）或 `webview`（实页渲染）。
  final String mode;

  /// 内容完整性提示（可能不完整时的说明）。
  final String? notice;

  /// Readability 解析出的发布时间（可缺）。
  final String publishedTime;

  /// 命中的登录墙/反爬标记。
  final String blockedReason;

  /// 页面是否含「展开全文」等折叠内容。
  final bool truncated;
}

enum WebCaptureError { network, timeout, empty, blocked, unsupported }

class WebCaptureException implements Exception {
  const WebCaptureException({required this.kind, required this.message});

  final WebCaptureError kind;
  final String message;

  @override
  String toString() => '$kind: $message';
}
