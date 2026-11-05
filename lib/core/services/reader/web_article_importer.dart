import 'dart:async';

import 'txt_importer.dart' show TxtChapter, TxtImporter;
import 'txt_to_epub.dart' show EpubChapter;
import 'web_capture.dart';

/// 网页文章抓取后的待入库数据。
class WebArticleImportData {
  const WebArticleImportData({
    required this.title,
    required this.author,
    required this.originUrl,
    required this.chapters,
    required this.textLength,
    this.notice,
    this.publishedTime = '',
  });

  final String title;
  final String author;
  final String originUrl;
  final List<EpubChapter> chapters;
  final int textLength;

  /// 内容完整性提示（例如页面有「展开全文」、可能只抓到可见部分）。
  final String? notice;

  /// 页面声明的发布时间（可缺，Readability 元数据）。
  final String publishedTime;
}

enum WebImportError {
  invalidUrl,
  network,
  empty,
  unsupported,
  blocked,
  timeout,
}

class WebImportException implements Exception {
  const WebImportException(this.kind, this.message);

  final WebImportError kind;
  final String message;

  @override
  String toString() => message;
}

/// 网页文章导入：
/// URL 校验 → 通用正文抓取（静态 HTML 优先，WebView 渲染兜底；
/// 网络/超时失败重试 1 次）→ 按标题/段落切章。
class WebArticleImporter {
  WebArticleImporter._();

  /// 少于该字数的正文视为提取失败（反爬页 / 登录墙 / 非文章页）。
  static const int minTextLength = 200;

  static Future<WebArticleImportData> fetch(String rawUrl) async {
    final url = _normalizeUrl(rawUrl);
    WebArticleResult result;
    try {
      result = await WebArticleCapture.capture(url);
    } on WebCaptureException catch (e) {
      if (e.kind != WebCaptureError.network &&
          e.kind != WebCaptureError.timeout) {
        throw _mapException(e);
      }
      // 网络/超时失败重试 1 次（短暂延时，避开瞬时抖动）。
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      try {
        result = await WebArticleCapture.capture(url);
      } on WebCaptureException catch (retryError) {
        throw _mapException(retryError);
      }
    } catch (e) {
      throw WebImportException(WebImportError.network, '抓取失败：$e');
    }

    if (result.textLength < minTextLength ||
        result.contentHtml.trim().isEmpty) {
      throw const WebImportException(
        WebImportError.empty,
        '未提取到足够正文（少于 200 字）：可能是首页/列表/视频等非文章页，'
        '或正文需要登录、交互后才会出现。',
      );
    }

    final title = result.title.trim().isEmpty
        ? _hostOf(url)
        : result.title.trim();
    final chapters = splitHtml(result.contentHtml, title: title);

    return WebArticleImportData(
      title: title,
      author: result.byline.trim(),
      originUrl: result.finalUrl.trim().isEmpty ? url : result.finalUrl.trim(),
      chapters: chapters,
      textLength: result.textLength,
      notice: result.notice,
      publishedTime: result.publishedTime,
    );
  }

  static WebImportException _mapException(WebCaptureException e) {
    return switch (e.kind) {
      WebCaptureError.network => WebImportException(
        WebImportError.network,
        e.message,
      ),
      WebCaptureError.timeout => WebImportException(
        WebImportError.timeout,
        e.message,
      ),
      WebCaptureError.empty => WebImportException(
        WebImportError.empty,
        e.message,
      ),
      WebCaptureError.blocked => WebImportException(
        WebImportError.blocked,
        e.message,
      ),
      WebCaptureError.unsupported => WebImportException(
        WebImportError.unsupported,
        e.message,
      ),
    };
  }

  static String _normalizeUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw const WebImportException(WebImportError.invalidUrl, '请输入文章链接');
    }
    final withScheme =
        trimmed.startsWith('http://') || trimmed.startsWith('https://')
        ? trimmed
        : 'https://$trimmed';
    final uri = Uri.tryParse(withScheme);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const WebImportException(
        WebImportError.invalidUrl,
        '链接格式不正确，仅支持 http(s) 网页',
      );
    }
    return withScheme;
  }

  static String _hostOf(String url) {
    final uri = Uri.tryParse(url);
    return uri?.host.isNotEmpty == true ? uri!.host : '网页文章';
  }

  /// 优先按 h1/h2 切章；无标题时按段落块与字数切分。
  static List<EpubChapter> splitHtml(String html, {required String title}) {
    final headingPattern = RegExp(
      r'<h[12][^>]*>([\s\S]*?)</h[12]>',
      caseSensitive: false,
    );
    final headings = headingPattern.allMatches(html).toList();

    if (headings.length >= 2) {
      final chapters = <EpubChapter>[];
      final intro = html.substring(0, headings.first.start);
      if (_textLength(intro) > 300) {
        chapters.add(EpubChapter(title: '导语', html: intro.trim()));
      }
      for (var i = 0; i < headings.length; i++) {
        final heading = headings[i];
        final end = i + 1 < headings.length
            ? headings[i + 1].start
            : html.length;
        final headingText = _stripTags(heading.group(1) ?? '').trim();
        final body = html.substring(heading.end, end).trim();
        final chapterTitle = headingText.isEmpty
            ? '第${chapters.length + 1}节'
            : headingText;
        chapters.add(EpubChapter(title: chapterTitle, html: body));
      }
      if (chapters.isNotEmpty) return chapters;
    }

    return _splitByParagraphs(html, title: title);
  }

  static List<EpubChapter> _splitByParagraphs(
    String html, {
    required String title,
  }) {
    final textChars = _textLength(html);
    if (textChars <= 20000) {
      return [EpubChapter(title: title, html: html.trim())];
    }

    final blockPattern = RegExp(
      r'<p\b[^>]*>[\s\S]*?</p>',
      caseSensitive: false,
    );
    final blocks = blockPattern
        .allMatches(html)
        .map((m) => m.group(0)!)
        .toList();
    if (blocks.isEmpty) {
      return [EpubChapter(title: title, html: html.trim())];
    }

    final chapters = <EpubChapter>[];
    final buffer = StringBuffer();
    var length = 0;
    void flush() {
      final content = buffer.toString().trim();
      if (content.isEmpty) return;
      chapters.add(
        EpubChapter(title: '第${chapters.length + 1}节', html: content),
      );
      buffer.clear();
      length = 0;
    }

    for (final block in blocks) {
      if (length + block.length > 8000) flush();
      buffer.write(block);
      length += block.length;
    }
    flush();
    if (chapters.isEmpty) {
      return [EpubChapter(title: title, html: html.trim())];
    }
    return chapters;
  }

  static int _textLength(String html) => _stripTags(html).trim().length;

  static String _stripTags(String html) =>
      html.replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'\s+'), ' ');

  /// 复用 TXT 的清洗/切章能力（供无标题长文兜底，单元测试直接调用）。
  static List<TxtChapter> splitPlainText(String text, {String title = '正文'}) =>
      TxtImporter.splitChapters(text, fallbackTitle: title);
}
