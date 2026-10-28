import 'dart:convert';

import 'package:dio/dio.dart';

import 'key_value_store.dart';

/// B 站接口路径常量（**相对路径**，域名由 [ApiConfig.apiBase] 拼装）。
///
/// R1：所有端点收敛在这里，接口改版只动这一个文件；
/// R1 热修复预留：`api_base` 等域名可由内置/远端 JSON 覆盖，不发版即可改。
class BiliPaths {
  BiliPaths._();

  /// 获取 WBI img_key / sub_key 及登录态
  static const String nav = '/x/web-interface/nav';

  /// 通用搜索（WBI 签名）
  static const String searchType = '/x/web-interface/wbi/search/type';

  /// UP 主空间投稿列表（匿名易被风控，慎用）
  static const String spaceArcSearch = '/x/space/wbi/arc/search';

  /// UP 主合集/系列列表（匿名可用的主要来源）
  static const String upCollections = '/x/polymer/web-space/seasons_series_list';

  /// 单个合集下的全部视频（分页）
  static const String upCollectionArchives =
      '/x/polymer/web-space/seasons_archives_list';

  /// 视频基本信息（含分P列表）
  static const String view = '/x/web-interface/view';

  /// 用户卡片（mid → 名字/头像，免 WBI 免风控）
  static const String userCard = '/x/web-interface/card';

  /// 分P列表
  static const String pageList = '/x/player/pagelist';

  /// 取流（DASH，fnval=16）
  static const String playUrl = '/x/player/wbi/playurl';

  /// buvid 激活（gaia 风控闭环：ExClimbWuzhi）
  static const String activateBuvid =
      '/x/internal/gaia-gateway/ExClimbWuzhi';

  /// 扫码登录：生成二维码（passport 域名，经 [ApiConfig.passportUrl] 拼装）
  static const String qrGenerate = '/x/passport-login/web/qrcode/generate';

  /// 扫码登录：轮询扫码结果（passport 域名，经 [ApiConfig.passportUrl] 拼装）
  static const String qrPoll = '/x/passport-login/web/qrcode/poll';
}

/// 接口配置：域名、UA、节流与退避参数。
class ApiConfig {
  /// API 域名。原生端为 `https://api.bilibili.com`；
  /// Web 预览为同源相对前缀 `/api`（由 `tool/dev_proxy.mjs` 反代，绕开 CORS）。
  final String apiBase;

  /// 网页站域名，用作 Referer/Origin 与首页预热。
  final String homeBase;

  /// passport 域名（扫码登录 generate/poll）。原生端为
  /// `https://passport.bilibili.com`；Web 预览为同源前缀 `/pp`（dev_proxy 反代）。
  final String passportBase;

  /// 搜索页域名（搜索类请求的合法来源）。
  final String searchHome;

  final String userAgent;

  /// 远端配置覆盖地址（R1 热修复）：静态 JSON，拉取失败静默回退内置配置。
  final String? remoteConfigUrl;

  /// 游客请求最小间隔（ms），见 R2：450ms 节流。
  final int minRequestGapMs;

  /// 风控退避阶梯（ms）：HTTP 412/403 或 body code -412/-352 时按序重试。
  final List<int> riskBackoffMs;

  /// 是否允许访问 `homeBase/` 做 Cookie 预热（Web 端跨域读不到 Set-Cookie，关闭）。
  final bool warmupEnabled;

  const ApiConfig({
    required this.apiBase,
    required this.homeBase,
    required this.passportBase,
    required this.searchHome,
    required this.userAgent,
    required this.remoteConfigUrl,
    required this.minRequestGapMs,
    required this.riskBackoffMs,
    required this.warmupEnabled,
  });

  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  /// 内置默认配置（不读任何文件也能跑）。
  factory ApiConfig.defaults({bool isWeb = false}) => ApiConfig(
        apiBase: isWeb ? '/api' : 'https://api.bilibili.com',
        homeBase: 'https://www.bilibili.com',
        passportBase: isWeb ? '/pp' : 'https://passport.bilibili.com',
        searchHome: 'https://search.bilibili.com',
        userAgent: defaultUserAgent,
        remoteConfigUrl: null,
        minRequestGapMs: 450,
        riskBackoffMs: const [1200, 2600, 5000],
        warmupEnabled: !isWeb,
      );

  /// 从 JSON 解析；`isWeb == true` 时强制同源反代前缀（CORS 限制）。
  factory ApiConfig.fromJson(Map<String, dynamic> json, {bool isWeb = false}) {
    final defaults = ApiConfig.defaults(isWeb: isWeb);
    return ApiConfig(
      apiBase: isWeb ? '/api' : '${json['api_base'] ?? defaults.apiBase}',
      homeBase: '${json['home_base'] ?? defaults.homeBase}',
      passportBase: isWeb ? '/pp' : '${json['passport_base'] ?? defaults.passportBase}',
      searchHome: '${json['search_home'] ?? defaults.searchHome}',
      userAgent: '${json['user_agent'] ?? defaults.userAgent}',
      remoteConfigUrl: json['remote_config_url'] as String?,
      minRequestGapMs:
          (json['min_request_gap_ms'] as num?)?.toInt() ?? defaults.minRequestGapMs,
      riskBackoffMs: (json['risk_backoff_ms'] as List?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          defaults.riskBackoffMs,
      warmupEnabled: isWeb ? false : (json['warmup_enabled'] as bool? ?? true),
    );
  }

  Map<String, dynamic> toJson() => {
        'api_base': apiBase,
        'home_base': homeBase,
        'passport_base': passportBase,
        'search_home': searchHome,
        'user_agent': userAgent,
        'remote_config_url': remoteConfigUrl,
        'min_request_gap_ms': minRequestGapMs,
        'risk_backoff_ms': riskBackoffMs,
        'warmup_enabled': warmupEnabled,
      };

  ApiConfig copyWith({String? apiBase}) => ApiConfig(
        apiBase: apiBase ?? this.apiBase,
        homeBase: homeBase,
        passportBase: passportBase,
        searchHome: searchHome,
        userAgent: userAgent,
        remoteConfigUrl: remoteConfigUrl,
        minRequestGapMs: minRequestGapMs,
        riskBackoffMs: riskBackoffMs,
        warmupEnabled: warmupEnabled,
      );

  /// 路径 → 完整 URL（已是绝对 URL 时原样返回）。
  String url(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    if (path.startsWith('/')) return '$apiBase$path';
    return '$apiBase/$path';
  }

  /// passport 路径 → 完整 URL（扫码登录专用域名）。
  String passportUrl(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    if (path.startsWith('/')) return '$passportBase$path';
    return '$passportBase/$path';
  }

  /// 首页预热地址（拿 buvid3 等基础 Cookie）。
  String? get warmupUrl => warmupEnabled ? '$homeBase/' : null;

  /// 解析结果摘要，便于日志与自检面板展示。
  String describe() =>
      'api_base=$apiBase  gap=${minRequestGapMs}ms  '
      'backoff=${riskBackoffMs.join('/')}ms  warmup=${warmupEnabled ? 'on' : 'off'}';
}

/// 配置加载：内置 JSON → 远端覆盖（带 TTL 缓存，失败静默回退）。
///
/// 对应 R1「接口配置远端热修复」预留：接口改版时先下发新配置应急。
class ApiConfigLoader {
  ApiConfigLoader._();

  static const String remoteCacheKey = 'api_config_remote_json';

  /// [bundledJson]：读取随包配置（App 传 `rootBundle.loadString`，CLI 传 null）。
  static Future<ApiConfig> load({
    required KeyValueStore store,
    bool isWeb = false,
    Future<String?> Function()? bundledJson,
    Duration remoteTtl = const Duration(hours: 6),
    Duration timeout = const Duration(seconds: 6),
  }) async {
    var config = ApiConfig.defaults(isWeb: isWeb);

    if (bundledJson != null) {
      try {
        final raw = await bundledJson();
        if (raw != null && raw.trim().isNotEmpty) {
          config = ApiConfig.fromJson(
            jsonDecode(raw) as Map<String, dynamic>,
            isWeb: isWeb,
          );
        }
      } catch (_) {
        // 配置损坏 → 回退默认值，绝不阻塞启动
      }
    }

    // 远端覆盖：命中缓存直接用；否则现拉一次（静态 JSON，不受 B 站风控约束）
    final remote = config.remoteConfigUrl;
    if (remote == null || remote.trim().isEmpty) return config;

    try {
      final cached = store.getString(remoteCacheKey);
      if (cached != null) {
        final map = jsonDecode(cached) as Map<String, dynamic>;
        final fetchedAt = (map['fetched_at'] as num?)?.toInt() ?? 0;
        final age = DateTime.now().millisecondsSinceEpoch - fetchedAt;
        if (age < remoteTtl.inMilliseconds) {
          return ApiConfig.fromJson(
            map['config'] as Map<String, dynamic>,
            isWeb: isWeb,
          );
        }
      }
      final res = await Dio(BaseOptions(
        connectTimeout: timeout,
        receiveTimeout: timeout,
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      )).get<String>(remote);
      final body = res.data;
      if (res.statusCode == 200 && body != null && body.trim().isNotEmpty) {
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        await store.setString(remoteCacheKey, jsonEncode({
          'fetched_at': DateTime.now().millisecondsSinceEpoch,
          'config': decoded,
        }));
        return ApiConfig.fromJson(decoded, isWeb: isWeb);
      }
    } catch (_) {
      // 拉取失败沿用内置配置（R1：热修复失败不能影响可用性）
    }
    return config;
  }
}
