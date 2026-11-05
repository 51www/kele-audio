/*
 * 通用网页正文提取脚本。
 *
 * 运行环境：Android WebView（注入）或 Node + jsdom（离线回归测试）。
 * 约定：页面需先加载 Readability.js（全局 function Readability）。
 *
 * 策略：
 * 1. Readability 解析（主路径）；
 * 2. 文本密度启发式兜底（不依赖站点选择器）；
 * 3. 识别登录墙 / 反爬验证页 / 内容折叠（「展开全文」）。
 *
 * 返回 JSON 字符串，由 Dart 侧解析。
 */
function extractArticle() {
  'use strict';

  var ERROR_TITLES = [
    '网页无法打开',
    '无法访问此网站',
    'This site can’t be reached',
    '404 Not Found',
    '400 Bad Request',
    'Error',
  ];
  var BLOCK_MARKERS = [
    '请输入验证码',
    '安全验证',
    '人机验证',
    '访问验证',
    '环境异常',
    '请完成验证',
    '登录后查看',
    '登录后继续阅读',
    '需要登录',
    'Just a moment',
    'Checking your browser',
    'Verify you are human',
    'Access denied',
    'Attention Required',
    '403 Forbidden',
    '404 Not Found',
  ];
  var TRUNCATE_MARKERS = [
    '展开阅读全文',
    '展开全文',
    '点击展开',
    '查看全部内容',
    '阅读更多',
  ];
  var NOISE_SELECTOR = [
    'script',
    'style',
    'noscript',
    'template',
    'nav',
    'header',
    'footer',
    'aside',
    'form',
    'iframe',
    '[role="navigation"]',
    '[role="complementary"]',
    '[role="banner"]',
    '[role="contentinfo"]',
    '[role="search"]',
    '[aria-modal="true"]',
    '[hidden]',
  ].join(',');
  var NOISE_CLASS_RE =
    /(^|[\s_-])(ad|ads|advert|advertisement|sponsor|sponsored|banner|comment|comments|share|social|related|recommend|recommendation|promo|promotion|newsletter|subscribe|cookie|popup|modal|sidebar|breadcrumb|breadcrumbs|nav|menu|toolbar)([\s_-]|$)/i;
  var KEEP_EMPTY_TAGS = [
    'img',
    'video',
    'audio',
    'source',
    'picture',
    'br',
    'hr',
    'svg',
  ];

  function rawText(el) {
    if (!el) return '';
    var text =
      typeof el.innerText === 'string' && el.innerText
        ? el.innerText
        : el.textContent || '';
    return text
      .replace(/\u00a0/g, ' ')
      .replace(/[ \t]+/g, ' ')
      .replace(/\n\s*\n\s*\n+/g, '\n\n')
      .trim();
  }

  function metaContent(key) {
    var el = document.querySelector(
      'meta[property="' + key + '"], meta[name="' + key + '"]'
    );
    return el ? (el.getAttribute('content') || '').trim() : '';
  }

  function pageTitle() {
    return (
      metaContent('og:title') ||
      metaContent('twitter:title') ||
      rawText(document.querySelector('h1')) ||
      (document.title || '').trim()
    );
  }

  function pageByline() {
    return (
      metaContent('article:author') ||
      metaContent('author') ||
      metaContent('twitter:creator')
    );
  }

  function isNoise(el) {
    if (!el || el.nodeType !== 1) return false;
    var cls =
      ((el.getAttribute && el.getAttribute('class')) || '') +
      ' ' +
      (el.id || '');
    return NOISE_CLASS_RE.test(cls);
  }

  function removeNode(el) {
    if (el && el.parentNode) el.parentNode.removeChild(el);
  }

  function cleanContainer(root) {
    var nodes = root.querySelectorAll(NOISE_SELECTOR);
    for (var i = nodes.length - 1; i >= 0; i--) removeNode(nodes[i]);
    var all = root.querySelectorAll('*');
    for (var j = all.length - 1; j >= 0; j--) {
      var el = all[j];
      if (isNoise(el)) removeNode(el);
    }
    var rest = root.querySelectorAll('*');
    for (var k = rest.length - 1; k >= 0; k--) {
      var node = rest[k];
      var tag = (node.tagName || '').toLowerCase();
      if (KEEP_EMPTY_TAGS.indexOf(tag) >= 0) continue;
      if (node.querySelector('img,video,audio,picture')) continue;
      if (rawText(node).length === 0) removeNode(node);
    }
    return root;
  }

  // 懒加载图片：把 data-src 等迁移到 src，并把相对地址补成绝对地址。
  function normalizeImages(root, baseUrl) {
    var images = root.querySelectorAll('img');
    for (var i = 0; i < images.length; i++) {
      var img = images[i];
      var lazy =
        img.getAttribute('data-src') ||
        img.getAttribute('data-original') ||
        img.getAttribute('data-lazy-src') ||
        img.getAttribute('data-actualsrc');
      var src = img.getAttribute('src') || '';
      if (lazy && (!src || /^data:/.test(src))) img.setAttribute('src', lazy);
      src = img.getAttribute('src') || '';
      if (src && !/^(https?:|data:|file:)/i.test(src)) {
        try {
          img.setAttribute('src', new URL(src, baseUrl).href);
        } catch (e) {
          // 忽略无法解析的相对地址
        }
      }
    }
    return root;
  }

  function cloneDocument() {
    var doc = new DOMParser().parseFromString(
      '<!doctype html>' + document.documentElement.outerHTML,
      'text/html'
    );
    revealHidden(doc);
    normalizeImages(doc, document.baseURI || location.href || '');
    return doc;
  }

  // 部分站点（如公众号）正文在脚本执行前以 visibility:hidden 占位；
  // 去掉该声明后正文才能被 Readability 识别。仅处理 visibility，不碰
  // display:none（后者多为菜单/弹窗/广告）。
  function revealHidden(doc) {
    var nodes = doc.querySelectorAll('[style]');
    for (var i = 0; i < nodes.length; i++) {
      var style = nodes[i].getAttribute('style') || '';
      if (/visibility\s*:\s*hidden/i.test(style)) {
        nodes[i].setAttribute(
          'style',
          style.replace(/visibility\s*:\s*hidden\s*;?/gi, '')
        );
      }
    }
  }

  function contentStats(html) {
    var holder = document.createElement('div');
    holder.innerHTML = html || '';
    var paragraphs = holder.querySelectorAll('p');
    var longParagraphs = 0;
    for (var i = 0; i < paragraphs.length; i++) {
      if (rawText(paragraphs[i]).length >= 40) longParagraphs++;
    }
    return {
      paragraphs: paragraphs.length,
      longParagraphs: longParagraphs,
      links: holder.querySelectorAll('a').length,
      linkText: (function () {
        var total = 0;
        var anchors = holder.querySelectorAll('a');
        for (var j = 0; j < anchors.length; j++) {
          total += rawText(anchors[j]).length;
        }
        return total;
      })(),
    };
  }

  function readWithReadability(doc) {
    try {
      if (typeof Readability !== 'function') return null;
      var parsed = new Readability(doc).parse();
      if (!parsed || !parsed.content || !parsed.textContent) return null;
      var text = (parsed.textContent || '').trim();
      if (text.length < 100) return null;
      var stats = contentStats(parsed.content);
      // 链接密度过高的「正文」多半是导航/列表页，交给兜底与上层判定。
      var density = stats.linkText / Math.max(1, text.length);
      if (text.length < 600 && density > 0.5) return null;
      return {
        title: parsed.title || '',
        byline: parsed.byline || '',
        publishedTime: parsed.publishedTime || '',
        html: parsed.content,
        text: text,
        source: 'readability',
        stats: stats,
      };
    } catch (e) {
      return null;
    }
  }

  function heuristicExtract(doc) {
    var candidates = doc.querySelectorAll(
      'article, main, [role="main"], [itemprop="articleBody"], section, div'
    );
    var best = null;
    var bestScore = 0;
    for (var i = 0; i < candidates.length; i++) {
      var el = candidates[i];
      var text = rawText(el);
      if (text.length < 200) continue;
      if (text.length > 120000 && el.tagName !== 'MAIN' && el.tagName !== 'ARTICLE') {
        continue;
      }
      var links = el.querySelectorAll('a');
      var linkText = 0;
      for (var j = 0; j < links.length; j++) {
        linkText += rawText(links[j]).length;
      }
      var density = linkText / Math.max(1, text.length);
      if (density > 0.4) continue;
      var score = text.length * (1 - density);
      var paragraphs = el.querySelectorAll('p').length;
      score += Math.min(paragraphs, 60) * 50;
      if (el.tagName === 'MAIN' || el.tagName === 'ARTICLE') score *= 1.2;
      if (el.getAttribute('itemprop') === 'articleBody') score *= 1.5;
      if (score > bestScore) {
        bestScore = score;
        best = el;
      }
    }
    if (!best) return null;
    var clone = best.cloneNode(true);
    normalizeImages(clone, document.baseURI || location.href || '');
    cleanContainer(clone);
    var text = rawText(clone);
    if (text.length < 100) return null;
    var html = clone.innerHTML;
    return {
      title: pageTitle(),
      byline: pageByline(),
      publishedTime: '',
      html: html,
      text: text,
      source: 'heuristic',
      stats: contentStats(html),
    };
  }

  function detectBlocked() {
    var href = (location.href || '').toLowerCase();
    if (
      /(^|\/)(signin|login|passport|challenge|captcha|verify|unhuman|authwall)(\/|$|\?|#)/.test(
        href
      )
    ) {
      return '页面跳转到了登录/验证地址';
    }
    var probe =
      (document.title || '') + ' ' + rawText(document.body).slice(0, 4000);
    for (var i = 0; i < BLOCK_MARKERS.length; i++) {
      if (probe.indexOf(BLOCK_MARKERS[i]) >= 0) return BLOCK_MARKERS[i];
    }
    return '';
  }

  function detectTruncated() {
    var text = rawText(document.body);
    for (var i = 0; i < TRUNCATE_MARKERS.length; i++) {
      if (text.indexOf(TRUNCATE_MARKERS[i]) >= 0) return TRUNCATE_MARKERS[i];
    }
    return '';
  }

  var blocked = detectBlocked();
  var truncated = detectTruncated();
  // Readability 解析会改动 DOM，兜底路径使用独立副本。
  var result = readWithReadability(cloneDocument());
  if (!result) result = heuristicExtract(cloneDocument());

  if (!result) {
    return JSON.stringify({
      ok: false,
      error: 'EMPTY',
      blocked: blocked,
      truncated: truncated,
      url: location.href || '',
    });
  }

  var title = (result.title || '').trim() || pageTitle();
  var byline = (result.byline || '').trim() || pageByline();
  var text = (result.text || '').trim();
  if (
    text.length < 100 ||
    ERROR_TITLES.indexOf(title) >= 0 ||
    text.indexOf('ERR_') >= 0
  ) {
    return JSON.stringify({
      ok: false,
      error: 'EMPTY',
      blocked: blocked,
      truncated: truncated,
      url: location.href || '',
    });
  }

  return JSON.stringify({
    ok: true,
    title: title,
    byline: byline,
    publishedTime: result.publishedTime || '',
    textLength: text.length,
    excerpt: text.substring(0, 160),
    content: result.html || '',
    paragraphs: result.stats ? result.stats.paragraphs : 0,
    longParagraphs: result.stats ? result.stats.longParagraphs : 0,
    links: result.stats ? result.stats.links : 0,
    blocked: blocked,
    truncated: truncated,
    source: result.source || '',
    url: location.href || '',
  });
}

/*
 * 展开被折叠的正文按钮（点击是公开页面交互，不涉及登录绕过）。
 * 只处理文案完全匹配的按钮，且最多点击 3 个，避免触发评论区加载。
 */
function expandCollapsedContent() {
  'use strict';
  var labels = ['展开阅读全文', '展开全文', '阅读全文', '查看全部内容', '展开'];
  var nodes = document.querySelectorAll('button, a, span, div[role="button"]');
  var clicked = 0;
  for (var i = 0; i < nodes.length && clicked < 3; i++) {
    var el = nodes[i];
    var text = (el.innerText || el.textContent || '').trim();
    if (labels.indexOf(text) < 0) continue;
    if (typeof el.click !== 'function') continue;
    try {
      el.click();
      clicked++;
    } catch (e) {
      // 忽略点击失败
    }
  }
  return clicked;
}
