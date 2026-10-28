// Web 预览用本地服务器：静态托管 build/web + 反代 /api/* → api.bilibili.com
//
//   node tool/dev_proxy.mjs            # 默认 http://localhost:8088
//   PORT=9000 node tool/dev_proxy.mjs
//
// 为什么需要它：
//  1) 浏览器有 CORS 限制，Dart 侧无法直连 api.bilibili.com；
//  2) 浏览器禁止设置 User-Agent / Referer / Cookie 这些「禁止头」，
//     而 B 站 CDN 与接口必须带。Dart 侧照常组装完整请求头（core/api），
//     另外镜像成 X-Kele-UA / X-Kele-Referer / X-Kele-Cookie，
//     这里负责还原成真实请求头后转发。
//
// 仅用于本地开发预览，不参与 Android 打包（Android 端直连，不走反代）。

import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const WEB_ROOT = path.resolve(__dirname, '../build/web');
const PORT = Number(process.env.PORT || 8088);
const API_BASE = process.env.API_BASE || 'https://api.bilibili.com';
const PASSPORT_BASE = process.env.PASSPORT_BASE || 'https://passport.bilibili.com';

const DEFAULT_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.wasm': 'application/wasm',
  '.ttf': 'font/ttf',
  '.map': 'application/json; charset=utf-8',
  '.bor': 'application/octet-stream',
};

const HOP_BY_HOP = new Set([
  'connection',
  'keep-alive',
  'transfer-encoding',
  'upgrade',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'set-cookie',
  'content-encoding',
  'content-length',
]);

// strip：前缀长度（/api → 4，/pp → 3），base：上游域名（api / passport）
async function proxyApi(req, res, url, base = API_BASE, strip = 4) {
  const target = `${base}${url.pathname.slice(strip)}${url.search}`;

  const headers = {
    'user-agent': pick(req, 'x-kele-ua', DEFAULT_UA),
    referer: pick(req, 'x-kele-referer', 'https://www.bilibili.com'),
    origin: new URL(pick(req, 'x-kele-referer', 'https://www.bilibili.com'))
      .origin,
    accept: req.headers.accept ?? 'application/json, text/plain, */*',
    'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8',
  };
  const cookie = pick(req, 'x-kele-cookie', '');
  if (cookie) headers.cookie = cookie;

  let body;
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    body = await new Promise((resolve) => {
      const chunks = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', () => resolve(Buffer.concat(chunks)));
    });
    if (req.headers['content-type']) {
      headers['content-type'] = req.headers['content-type'];
    }
  }

  const started = Date.now();
  try {
    const upstream = await fetch(target, {
      method: req.method,
      headers,
      body,
      redirect: 'manual',
    });
    const buf = Buffer.from(await upstream.arrayBuffer());
    const out = {};
    for (const [k, v] of upstream.headers) {
      if (!HOP_BY_HOP.has(k.toLowerCase())) out[k] = v;
    }
    out['x-kele-via'] = `dev_proxy ${Date.now() - started}ms`;
    res.writeHead(upstream.status, out);
    res.end(buf);
    console.log(
      `[api] ${req.method} ${url.pathname}${url.search} -> ${upstream.status} ` +
        `(${Date.now() - started}ms, ${buf.length}B)`,
    );
  } catch (err) {
    res.writeHead(502, { 'content-type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ code: -1, message: `dev_proxy: ${err.message}` }));
    console.error(`[api] FAIL ${target}: ${err.message}`);
  }
}

function pick(req, key, fallback) {
  const v = req.headers[key];
  return typeof v === 'string' && v.length > 0 ? v : fallback;
}

// ───────────────────────────────────────────────── /audio 音频反代（M2）
//
// Web 端浏览器禁止给 <video>/<audio> 设置 UA / Referer（「禁止头」），
// 而 B 站 CDN 缺一即 403。media_kit Web 端把音源改写成
//   /audio?u=<encoded>&ref=<encoded>&ua=<encoded>
// 这里还原请求头后**流式转发**，并透传 Range（长音频边下边播 + 断点续传）。
async function proxyAudio(req, res, url) {
  let target;
  try {
    target = decodeURIComponent(url.searchParams.get('u') || '');
  } catch {
    target = '';
  }
  if (!/^https?:\/\//.test(target)) {
    res.writeHead(400, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('缺少或非法的 u 参数（应为完整音频 URL）');
    return;
  }

  const referer = url.searchParams.get('ref') || 'https://www.bilibili.com';
  const ua = url.searchParams.get('ua') || DEFAULT_UA;
  const headers = {
    'user-agent': ua,
    referer,
    origin: (() => {
      try {
        return new URL(referer).origin;
      } catch {
        return 'https://www.bilibili.com';
      }
    })(),
    accept: '*/*',
    'accept-encoding': 'identity', // 音频不压缩，且 Range 与 gzip 不兼容
  };
  // 关键：Range 透传（播放器拖动进度 / 长音频分段拉取都靠它）
  if (req.headers.range) headers.range = req.headers.range;

  const started = Date.now();
  const upstream = httpsOrHttp(target, { method: 'GET', headers });
  upstream.on('response', (up) => {
    const out = {};
    for (const [k, v] of Object.entries(up.headers)) {
      if (!HOP_BY_HOP.has(k.toLowerCase())) out[k] = v;
    }
    out['access-control-allow-origin'] = '*'; // 本地预览放开
    out['x-kele-via'] = `dev_proxy/audio ${Date.now() - started}ms`;
    res.writeHead(up.statusCode || 502, out);
    up.pipe(res); // 流式：不把整段音频缓冲进内存
    console.log(
      `[audio] ${up.statusCode} ${new URL(target).pathname} ` +
        `range=${req.headers.range ?? '-'} (${Date.now() - started}ms)`,
    );
  });
  upstream.on('error', (err) => {
    if (!res.headersSent) {
      res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
    }
    res.end(`dev_proxy/audio: ${err.message}`);
    console.error(`[audio] FAIL ${target}: ${err.message}`);
  });
  upstream.end();
}

// ───────────────────────────────────────────────── /img 图片反代（M3）
//
// 与 /audio 同理：浏览器环境（无外网直连/跨域）下封面图走本地反代，
//   /img?u=<encoded 图片 URL>
// 回补 CORS 头 + 缓存头（同一封面多处复用，交给 HTTP 缓存）。
async function proxyImg(req, res, url) {
  let target;
  try {
    target = decodeURIComponent(url.searchParams.get('u') || '');
  } catch {
    target = '';
  }
  if (!/^https?:\/\//.test(target)) {
    res.writeHead(400, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('缺少或非法的 u 参数（应为完整图片 URL）');
    return;
  }
  const headers = {
    'user-agent': DEFAULT_UA,
    referer: 'https://www.bilibili.com',
    accept: 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
  };
  const started = Date.now();
  try {
    const upstream = await fetch(target, { headers, redirect: 'follow' });
    const buf = Buffer.from(await upstream.arrayBuffer());
    res.writeHead(upstream.status, {
      'content-type': upstream.headers.get('content-type') || 'image/jpeg',
      'access-control-allow-origin': '*',
      'cache-control': 'public, max-age=604800',
      'x-kele-via': `dev_proxy/img ${Date.now() - started}ms`,
    });
    res.end(buf);
    console.log(`[img] ${upstream.status} ${buf.length}B (${Date.now() - started}ms)`);
  } catch (err) {
    if (!res.headersSent) {
      res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
    }
    res.end(`dev_proxy/img: ${err.message}`);
    console.error(`[img] FAIL ${target}: ${err.message}`);
  }
}

function httpsOrHttp(target, options) {
  // 用 node:http / node:https 的底层 request 保持流式与 Range 语义，
  // 不用 fetch（fetch 会缓冲整段 body）。
  return target.startsWith('https:')
    ? https.request(target, options)
    : http.request(target, options);
}

function serveStatic(req, res, url) {
  if (!fs.existsSync(WEB_ROOT)) {
    res.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' });
    res.end(
      'build/web 不存在，请先执行：flutter build web\n' +
        `(期望路径：${WEB_ROOT})`,
    );
    return;
  }

  let rel = decodeURIComponent(url.pathname);
  if (rel.endsWith('/')) rel += 'index.html';
  let file = path.join(WEB_ROOT, rel);

  // 目录穿越保护
  if (!file.startsWith(WEB_ROOT)) {
    res.writeHead(403).end('forbidden');
    return;
  }
  if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    file = path.join(WEB_ROOT, 'index.html'); // SPA 回退
  }
  const type = MIME[path.extname(file).toLowerCase()] ?? 'application/octet-stream';
  res.writeHead(200, {
    'content-type': type,
    'cache-control': 'no-cache',
    // 允许本地调试脚本注入
    'access-control-allow-origin': '*',
  });
  fs.createReadStream(file).pipe(res);
}

http
  .createServer((req, res) => {
    const url = new URL(req.url, `http://localhost:${PORT}`);
    if (url.pathname === '/api' || url.pathname.startsWith('/api/')) {
      void proxyApi(req, res, url, API_BASE, 4);
    } else if (url.pathname === '/pp' || url.pathname.startsWith('/pp/')) {
      // 扫码登录（passport 域名）：ApiConfig.passportBase 的 Web 前缀
      void proxyApi(req, res, url, PASSPORT_BASE, 3);
    } else if (url.pathname === '/audio') {
      void proxyAudio(req, res, url);
    } else if (url.pathname === '/img') {
      void proxyImg(req, res, url);
    } else if (url.pathname === '/__health') {
      res.writeHead(200, { 'content-type': 'text/plain' }).end('ok');
    } else {
      serveStatic(req, res, url);
    }
  })
  .listen(PORT, () => {
    console.log(`kele-audio web preview → http://localhost:${PORT}`);
    console.log(`  static: ${WEB_ROOT}`);
    console.log(`  api   : ${API_BASE}  (via /api/*)`);
    console.log(`  login : ${PASSPORT_BASE}  (via /pp/*)`);
    console.log('  audio : /audio?u=<url>&ref=<referer>&ua=<ua>  (M2 音频反代)');
    console.log('  img   : /img?u=<url>  (M3 封面图反代)');
  });
