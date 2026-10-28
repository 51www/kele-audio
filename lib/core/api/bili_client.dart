import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import 'api_config.dart';
import 'cookie_jar.dart';
import 'key_value_store.dart';
import 'wbi_signer.dart';

/// 接口错误：统一抛给上层做提示（-412/-352 归一为「网络繁忙」）。
class BiliApiException implements Exception {
  BiliApiException(this.code, this.message);

  final int? code;
  final String message;

  @override
  String toString() => message;
}

/// 一次请求的可观测快照（M1 自检面板展示用）。
class RequestTrace {
  const RequestTrace({
    required this.method,
    required this.url,
    required this.headers,
    required this.statusCode,
    required this.elapsedMs,
    required this.riskHit,
    this.bodyBrief,
  });

  final String method;
  final String url;
  final Map<String, String> headers;
  final int? statusCode;
  final int elapsedMs;
  final bool riskHit;
  final String? bodyBrief;

  Map<String, Object?> toMap() => {
        'method': method,
        'url': url,
        'headers': headers,
        'status': statusCode,
        'elapsed_ms': elapsedMs,
        'risk_hit': riskHit,
      };
}

/// B 站客户端：Cookie 预热 + buvid 激活 + WBI 签名 + 统一请求头 + 风控兜底。
///
/// 移植自 abts（MIT）`lib/core/network/bili_client.dart`，改造点：
/// 1. 去掉 Flutter 依赖（`debugPrint` → 注入的 `log`），可用 `dart run` 跑冒烟；
/// 2. 域名/节流/退避参数化（[ApiConfig]，R1 远端配置热修复预留）；
/// 3. 持久化改走 [KeyValueStore] 抽象；
/// 4. Web 预览额外镜像 `X-Kele-*` 请求头，交由 `tool/dev_proxy.mjs` 反代注入
///    （浏览器禁止设置 User-Agent / Referer / Cookie 这些「禁止头」）。
///
/// 风控口径（R2，勿改）：全局 450ms 节流、HTTP 412/403 或 body code
/// -412/-352 阶梯退避 `[1200, 2600, 5000]`、WBI key 日刷新。
class BiliClient {
  BiliClient({
    required this.config,
    required this.kv,
    this.log,
    this.traceEnabled = true,
  });

  final ApiConfig config;
  final KeyValueStore kv;
  final void Function(String message)? log;
  final bool traceEnabled;

  static const String prefCookie = 'bili_cookie';
  static const String prefWbi = 'bili_wbi_keys';

  late Dio _dio;
  final CookieJar jar = CookieJar();

  String? _imgUrl;
  String? _subUrl;
  int _wbiFetchedAt = 0;
  bool _buvidActivated = false;
  int _lastReqAt = 0;
  RequestTrace? _lastTrace;

  bool _ready = false;

  RequestTrace? get lastTrace => _lastTrace;

  bool get wbiKeyReady => _imgUrl != null && _subUrl != null;

  void _log(String msg) => log?.call(msg);

  // ---------------------------------------------------------------- 初始化

  /// 本地初始化（启动关键路径，零网络）：建 Dio、恢复 Cookie / WBI 缓存。
  Future<void> initLocal() async {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 30),
      responseType: ResponseType.json,
    ));
    final cookie = kv.getString(prefCookie);
    if (cookie != null && cookie.isNotEmpty) {
      final map = <String, String>{};
      for (final seg in cookie.split(';')) {
        final eq = seg.indexOf('=');
        if (eq > 0) {
          map[seg.substring(0, eq).trim()] = seg.substring(eq + 1).trim();
        }
      }
      jar.mergeFromMap(map);
    }
    final wbi = kv.getString(prefWbi);
    if (wbi != null) {
      final parts = wbi.split('|');
      if (parts.length == 3) {
        _imgUrl = parts[0];
        _subUrl = parts[1];
        _wbiFetchedAt = int.tryParse(parts[2]) ?? 0;
      }
    }
    _ready = true;
  }

  Future<void> _ensureReady() async {
    if (!_ready) await initLocal();
  }

  /// 网络预热（进主界面后后台执行，绝不阻塞启动）：种 buvid → 激活 → 刷 WBI key。
  Future<void> warmupIfNeeded() async {
    await _ensureReady();
    if ((!jar.ready || config.warmupEnabled) && _needFreshWbiKeys()) {
      await warmup();
    }
    await _ensureBuvidActivated();
    if (_needFreshWbiKeys()) await _refreshWbiKeys();
  }

  bool _needFreshWbiKeys() {
    if (_imgUrl == null || _subUrl == null) return true;
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    return _wbiFetchedAt < day.millisecondsSinceEpoch;
  }

  Future<void> _persist() async {
    final cookie = jar.buildHeader();
    if (cookie.isNotEmpty) {
      await kv.setString(prefCookie, cookie);
    } else {
      await kv.remove(prefCookie);
    }
    if (_imgUrl != null && _subUrl != null) {
      await kv.setString(prefWbi, '$_imgUrl|$_subUrl|$_wbiFetchedAt');
    }
  }

  /// 预热：访问首页种入 buvid（Web 端跳过跨域首页），并刷新 WBI 密钥。
  Future<void> warmup() async {
    await _ensureReady();
    final warm = config.warmupUrl;
    if (warm != null) {
      try {
        final res = await _fetchRaw(warm, headers: {'Referer': warm});
        jar.mergeFromHeaders(res.headers['set-cookie']);
        jar.markSuccess();
        _log('[api] warmup cookie ok: ${jar.keys.join(',')}');
      } catch (e) {
        _log('[api] warmup failed: $e');
      }
    }
    // 本地直接种入 buvid3/buvid4：缺设备标识极易被判 412（Web 端无法读
    // Set-Cookie，只能走本地种入这条路径）
    if ((jar.get('buvid3') ?? '').isEmpty) jar.put('buvid3', genBuvid3());
    if ((jar.get('buvid4') ?? '').isEmpty) jar.put('buvid4', genBuvid3());
    await _persist();
    await _ensureBuvidActivated();
    await _refreshWbiKeys();
  }

  /// gaia 风控闭环：本地补齐 buvid 后上报 ExClimbWuzhi，把匿名游客伪装成
  /// 「活跃设备」，显著降低 v_voucher / -412 概率。
  Future<void> _ensureBuvidActivated() async {
    await _ensureReady();
    if (_buvidActivated) return;
    _buvidActivated = true;
    try {
      if ((jar.get('buvid3') ?? '').isEmpty) jar.put('buvid3', genBuvid3());
      if ((jar.get('buvid4') ?? '').isEmpty) jar.put('buvid4', genBuvid3());
      jar.put('b_nut', '${DateTime.now().millisecondsSinceEpoch}');
      await _persist();

      final rnd = Random();
      final png = base64.encode([
        for (var i = 0; i < 32; i++) rnd.nextInt(256),
        0, 0, 0, 0, 73, 69, 78, 68,
        for (var i = 0; i < 4; i++) rnd.nextInt(256),
      ]);
      final payload = jsonEncode({
        '3064': 1,
        '39c8': '333.1387.fp.risk',
        '3c43': {
          'adca': 'Linux',
          'bfe9': png.substring(png.length - 50),
        },
      });
      await post(config.url(BiliPaths.activateBuvid), data: {'payload': payload});
      _log('[api] buvid activated: ${jar.get('buvid3')}');
    } catch (e) {
      _log('[api] buvid activate failed: $e');
    }
  }

  Future<void> _refreshWbiKeys() async {
    await _ensureReady();
    try {
      final res = await _fetchRaw(
        config.url(BiliPaths.nav),
        headers: {'Referer': config.homeBase},
      );
      jar.mergeFromHeaders(res.headers['set-cookie']);
      final data = res.data;
      if (data is Map && data['data'] is Map && data['data']['wbi_img'] is Map) {
        final wbi = data['data']['wbi_img'] as Map;
        final img = wbi['img_url'] as String?;
        final sub = wbi['sub_url'] as String?;
        if (img != null && sub != null) {
          _imgUrl = img;
          _subUrl = sub;
          _wbiFetchedAt = DateTime.now().millisecondsSinceEpoch;
          _log('[api] wbi keys refreshed');
        }
      }
      if (data is Map && data['code'] == 0) jar.markSuccess();
      await _persist();
    } catch (e) {
      _log('[api] refresh wbi keys failed: $e');
    }
  }

  // ---------------------------------------------------------------- 请求

  /// 组装一次请求真正会带上的头（自检面板逐条展示）。
  Map<String, String> buildHeaders({required String referer}) {
    final cookie = jar.buildHeader();
    return {
      'User-Agent': config.userAgent,
      'Referer': referer,
      'Origin': Uri.parse(referer).origin,
      if (cookie.isNotEmpty) 'Cookie': cookie,
      // 浏览器会忽略上面三类「禁止头」，Web 反代靠 X-Kele-* 还原
      'X-Kele-UA': config.userAgent,
      'X-Kele-Referer': referer,
      if (cookie.isNotEmpty) 'X-Kele-Cookie': cookie,
    };
  }

  Future<Response<dynamic>> _fetchRaw(
    String url, {
    Map<String, String>? headers,
    ResponseType? responseType,
    String method = 'GET',
    Object? data,
  }) async {
    final referer = headers?['Referer'] ?? config.homeBase;
    final merged = <String, String>{
      ...buildHeaders(referer: referer),
      ...?headers,
    };
    final sw = Stopwatch()..start();
    try {
      final res = method == 'POST'
          ? await _dio.post<dynamic>(
              url,
              data: data,
              options: Options(
                headers: merged,
                contentType:
                    data is String ? Headers.jsonContentType : null,
                responseType: responseType ?? ResponseType.json,
                validateStatus: (_) => true,
              ),
            )
          : await _dio.get<dynamic>(
              url,
              options: Options(
                headers: merged,
                responseType: responseType ??
                    (url == config.warmupUrl
                        ? ResponseType.plain
                        : ResponseType.json),
                validateStatus: (_) => true,
              ),
            );
      sw.stop();
      if (traceEnabled) {
        _lastTrace = RequestTrace(
          method: method,
          url: url,
          headers: merged,
          statusCode: res.statusCode,
          elapsedMs: sw.elapsedMilliseconds,
          riskHit: _isRiskResponse(res),
          bodyBrief: _brief(res.data),
        );
      }
      return res;
    } finally {
      sw.stop();
    }
  }

  static String _brief(Object? data) {
    if (data == null) return 'null';
    final s = data is String ? data : jsonEncode(data);
    return s.length > 600 ? '${s.substring(0, 600)}…' : s;
  }

  /// 游客请求最小间隔，避免连续快打触发风控（R2：默认 450ms）。
  Future<void> _throttle() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final wait = config.minRequestGapMs - (now - _lastReqAt);
    if (wait > 0) {
      await Future<void>.delayed(Duration(milliseconds: wait));
    }
    _lastReqAt = DateTime.now().millisecondsSinceEpoch;
  }

  /// 部分接口 content-type 非 JSON，dio 保留原始字符串，这里统一尝试解码。
  static Response<dynamic> _normalize(Response<dynamic> res) {
    final d = res.data;
    if (d is String && d.isNotEmpty) {
      final t = d.trimLeft();
      if (t.startsWith('{') || t.startsWith('[')) {
        try {
          return Response<dynamic>(
            data: jsonDecode(d),
            statusCode: res.statusCode,
            statusMessage: res.statusMessage,
            headers: res.headers,
            isRedirect: res.isRedirect,
            redirects: res.redirects,
            requestOptions: res.requestOptions,
            extra: res.extra,
          );
        } catch (_) {
          // 非 JSON，原样返回
        }
      }
    }
    return res;
  }

  static bool _riskCode(int c) => c == -412 || c == -352;

  /// 判断是否风控拦截：HTTP 412/403 或 body code -412/-352
  static bool _isRiskResponse(Response<dynamic> res) {
    final sc = res.statusCode ?? 0;
    if (sc == 412 || sc == 403) return true;
    final d = res.data;
    if (d is Map) {
      final code = int.tryParse('${d['code'] ?? 0}') ?? 0;
      if (_riskCode(code)) return true;
    }
    return false;
  }

  /// 命中风控时的补救：补齐设备标识并重新预热。
  Future<void> _mitigateRisk() async {
    try {
      if ((jar.get('buvid3') ?? '').isEmpty) {
        jar.put('buvid3', genBuvid3());
        jar.put('buvid4', genBuvid3());
      }
      jar.put('b_nut', '${DateTime.now().millisecondsSinceEpoch}');
      await _persist();
      await warmup();
    } catch (e) {
      _log('[api] risk mitigate failed: $e');
    }
  }

  /// 通用 GET：带 Cookie、可 WBI 签名、风控阶梯退避重试。
  Future<Response<dynamic>> get(
    String url, {
    Map<String, dynamic>? query,
    bool useWbi = false,
    Map<String, String>? headers,
  }) async {
    await _ensureReady();
    await _throttle();
    var q = {...?query};
    if (useWbi) {
      if (_imgUrl == null || _subUrl == null || _needFreshWbiKeys()) {
        await _refreshWbiKeys();
      }
      if (_imgUrl == null || _subUrl == null) {
        throw BiliApiException(-401, 'WBI 密钥获取失败，请检查网络后重试');
      }
      q = WbiSigner.sign(q, imgUrl: _imgUrl!, subUrl: _subUrl!);
    }
    final fullUrl = q.isEmpty
        ? url
        : Uri.parse(url)
            .replace(
              queryParameters: Map<String, String>.fromEntries(
                q.entries.map((e) => MapEntry(e.key, '${e.value}')),
              ),
            )
            .toString();

    final baseHeaders = <String, String>{
      'Referer': config.homeBase,
      ...?headers,
    };

    try {
      var res = await _fetchRaw(fullUrl, headers: baseHeaders);
      for (var i = 0;
          _isRiskResponse(res) && i < config.riskBackoffMs.length;
          i++) {
        final wait = config.riskBackoffMs[i];
        _log('[api] risk hit, backoff ${wait}ms (try ${i + 1})');
        await Future<void>.delayed(Duration(milliseconds: wait));
        if (i == 0) await _mitigateRisk();
        res = await _fetchRaw(fullUrl, headers: baseHeaders);
      }
      final last = res.data;
      final sc = res.statusCode;
      if (last is! Map && sc != null && sc >= 400) {
        throw BiliApiException(sc, 'HTTP $sc');
      }
      if (last is Map) {
        final code = last['code'];
        final message = last['message'] ?? last['msg'] ?? '';
        if (code != null && code != 0) {
          final c = code is int ? code : int.tryParse('$code') ?? -1;
          throw BiliApiException(
            _riskCode(c) ? -412 : c,
            _riskCode(c) ? '网络繁忙，请稍后再试' : '$c：$message',
          );
        }
      }
      return res;
    } on DioException catch (e) {
      throw BiliApiException(-1, '网络请求失败：${e.message}');
    }
  }

  /// 通用 POST：带 Cookie、JSON 体、网络失败与风控码自动重试。
  Future<Response<dynamic>> post(
    String url, {
    Map<String, dynamic>? data,
    Map<String, String>? headers,
  }) async {
    await _ensureReady();
    await _throttle();
    final body = jsonEncode(data ?? const {});
    final baseHeaders = <String, String>{
      'Referer': config.homeBase,
      ...?headers,
    };

    Future<Response<dynamic>> send() =>
        _fetchRaw(url, headers: baseHeaders, method: 'POST', data: body);

    Response<dynamic>? res;
    Object? lastErr;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        res = await send();
        break;
      } catch (e) {
        lastErr = e;
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 800));
        }
      }
    }
    if (res == null) throw BiliApiException(-1, '网络请求失败：$lastErr');

    var resp = _normalize(res);
    jar.mergeFromHeaders(resp.headers['set-cookie']);
    for (var i = 0;
        _isRiskResponse(resp) && i < config.riskBackoffMs.length;
        i++) {
      _log('[api] POST risk hit, backoff ${config.riskBackoffMs[i]}ms');
      await Future<void>.delayed(Duration(milliseconds: config.riskBackoffMs[i]));
      try {
        resp = _normalize(await send());
      } catch (e) {
        lastErr = e;
      }
      jar.mergeFromHeaders(resp.headers['set-cookie']);
    }
    await _persist();
    final payload = resp.data;
    if (payload is Map) {
      final code = payload['code'];
      final message = payload['message'] ?? payload['msg'] ?? '';
      if (code != null && code != 0) {
        final c = code is int ? code : int.tryParse('$code') ?? -1;
        throw BiliApiException(
          _riskCode(c) ? -412 : c,
          _riskCode(c) ? '网络繁忙，请稍后再试' : '$c：$message',
        );
      }
    }
    return resp;
  }

  // ---------------------------------------------------------------- 杂项

  bool get isLoggedIn => (jar.get('SESSDATA') ?? '').isNotEmpty;

  /// 扫码登录成功后写入会话 Cookie（crossDomain URL 参数），并持久化。
  Future<void> acceptLoginCookies(Map<String, String> cookies) async {
    if (cookies.isEmpty) return;
    jar.mergeFromMap(cookies);
    jar.markSuccess();
    await _persist();
  }

  /// 合并响应头 Set-Cookie 并持久化（扫码轮询等 GET 响应用）。
  Future<void> absorbSetCookies(List<String>? setCookies) async {
    if (setCookies == null || setCookies.isEmpty) return;
    jar.mergeFromHeaders(setCookies);
    await _persist();
  }

  /// 解除登录：只清会话 Cookie，**保留 buvid 等设备指纹**（R2 风控连续性）。
  Future<void> logout() async {
    const keep = {'buvid3', 'buvid4', 'b_nut'};
    for (final key in jar.keys.toList()) {
      if (!keep.contains(key)) jar.remove(key);
    }
    await _persist();
  }

  /// 生成本地 buvid3（UUID 大写 + 5 位随机 + infoc）
  static String genBuvid3() {
    final rnd = Random();
    String hex(int n) {
      final sb = StringBuffer();
      for (var i = 0; i < n; i++) {
        sb.write(rnd.nextInt(16).toRadixString(16));
      }
      return sb.toString();
    }

    final uuid =
        '${hex(8)}-${hex(4)}-4${hex(3)}-${(8 + rnd.nextInt(4)).toRadixString(16)}${hex(3)}-${hex(12)}';
    final suffix = rnd.nextInt(100000).toString().padLeft(5, '0');
    return '${uuid.toUpperCase()}${suffix}infoc';
  }
}
