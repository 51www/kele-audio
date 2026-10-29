import 'package:dio/dio.dart';

import 'api_config.dart';
import 'bili_client.dart';

/// B 站账号档案（nav 接口登录态字段）。
class BiliAccount {
  const BiliAccount({
    required this.mid,
    required this.uname,
    required this.face,
    this.vipType = 0,
    this.vipStatus = 0,
  });

  final int mid;
  final String uname;
  final String face;

  /// 大会员类型（0=无/1=月度/2=年度…，nav `vip.type` 或 `vipType`）。
  final int vipType;

  /// 大会员状态（0=无 1=生效中，nav `vip.status` 或 `vipStatus`）。
  final int vipStatus;

  /// 大会员生效中（Hi-Res 解锁条件）。
  bool get isVip => vipStatus == 1 && vipType > 0;

  /// 解析 nav 接口的 `data` 载荷（纯函数，单测覆盖）。
  ///
  /// 会员字段双形态兼容：优先 `data.vip.{type,status}`，
  /// 回退 `data.{vipType,vipStatus}`；`isLogin != true` 返回 null。
  static BiliAccount? fromNavData(Map<String, dynamic> data) {
    if (data['isLogin'] != true) return null;
    return BiliAccount(
      mid: (data['mid'] as num?)?.toInt() ?? 0,
      uname: '${data['uname'] ?? ''}',
      face: '${data['face'] ?? ''}',
      vipType: _vipInt(data, 'type', 'vipType'),
      vipStatus: _vipInt(data, 'status', 'vipStatus'),
    );
  }

  static int _vipInt(Map<String, dynamic> data, String nested, String flat) {
    final vip = data['vip'];
    if (vip is Map) {
      final v = (vip[nested] as num?)?.toInt();
      if (v != null) return v;
    }
    return (data[flat] as num?)?.toInt() ?? 0;
  }

  Map<String, Object?> toJson() => {
        'mid': mid,
        'uname': uname,
        'face': face,
        'vipType': vipType,
        'vipStatus': vipStatus,
      };

  factory BiliAccount.fromJson(Map<String, dynamic> json) => BiliAccount(
        mid: (json['mid'] as num?)?.toInt() ?? 0,
        uname: '${json['uname'] ?? ''}',
        face: '${json['face'] ?? ''}',
        vipType: (json['vipType'] as num?)?.toInt() ?? 0,
        vipStatus: (json['vipStatus'] as num?)?.toInt() ?? 0,
      );
}

/// 扫码登录票据（qrGenerate 返回）：[qrContent] 是渲染成二维码的链接。
class QrTicket {
  const QrTicket({required this.qrContent, required this.qrcodeKey});

  final String qrContent;
  final String qrcodeKey;
}

/// 扫码轮询状态（abts 口径：data.code 0/86038/86090/86101）。
enum QrScanStatus {
  /// 等待扫码（86101）
  waiting,

  /// 已扫码，等待手机确认（86090）
  scanned,

  /// 确认成功，登录态在 [QrPollResult.cookies]（0）
  success,

  /// 二维码已失效（86038）
  expired,
}

/// 一次轮询结果：[QrScanStatus.success] 时 [cookies] 含 SESSDATA 等会话 Cookie。
class QrPollResult {
  const QrPollResult({
    required this.status,
    this.cookies = const {},
    this.refreshToken,
  });

  final QrScanStatus status;
  final Map<String, String> cookies;
  final String? refreshToken;

  /// 解析 qrPoll 的 `data` 载荷（纯函数，单测覆盖）。
  static QrPollResult parsePollData(Map<String, dynamic> data) {
    final code = (data['code'] as num?)?.toInt() ?? 86101;
    final status = switch (code) {
      0 => QrScanStatus.success,
      86038 => QrScanStatus.expired,
      86090 => QrScanStatus.scanned,
      _ => QrScanStatus.waiting,
    };
    return QrPollResult(
      status: status,
      cookies: status == QrScanStatus.success
          ? parseLoginCookies('${data['url'] ?? ''}')
          : const {},
      refreshToken: data['refresh_token'] as String?,
    );
  }

  /// 从确认成功返回的 crossDomain URL 解析会话 Cookie
  /// （DedeUserID / SESSDATA / bili_jct 等；`gourl` 不是 Cookie）。
  static Map<String, String> parseLoginCookies(String crossDomainUrl) {
    final uri = Uri.tryParse(crossDomainUrl);
    if (uri == null) return const {};
    final out = <String, String>{};
    uri.queryParameters.forEach((key, value) {
      if (key == 'gourl' || value.isEmpty) return;
      out[key] = value;
    });
    return out;
  }
}

/// 扫码登录/账号信息网关（[BiliAccountService] 依赖倒置，单测可换假实现）。
abstract class QrLoginGateway {
  /// 生成登录二维码。
  Future<QrTicket> generateQr();

  /// 轮询扫码状态（实现内负责合并响应 Set-Cookie）。
  Future<QrPollResult> pollQr(String qrcodeKey);

  /// 拉取当前登录档案；未登录返回 null。
  Future<BiliAccount?> fetchAccount();
}

/// 扫码登录（移植自 abts（MIT）`bili_api.dart` L585-616）：
/// qrGenerate → qrPoll 轮询（0=success / 86038=expired / 86090=scanned /
/// 86101=waiting），确认后从 crossDomain URL 解析 SESSDATA 等 Cookie。
///
/// 走 [BiliClient] 统一节流/风控退避（R2 勿另起一套）；
/// 登录态仅存本地（PRD §7.6），不做任何代登录。
class BiliLoginApi implements QrLoginGateway {
  BiliLoginApi({required this.client, ApiConfig? config, this.log})
      : config = config ?? client.config;

  final BiliClient client;
  final ApiConfig config;
  final void Function(String message)? log;

  @override
  Future<QrTicket> generateQr() async {
    final res = await client.get(
      config.passportUrl(BiliPaths.qrGenerate),
      query: {'source': 'main-fe-header'},
    );
    final data = _dataMap(res);
    final content = '${data['url'] ?? ''}';
    final key = '${data['qrcode_key'] ?? ''}';
    if (content.isEmpty || key.isEmpty) {
      throw BiliApiException(-1, '二维码获取失败');
    }
    return QrTicket(qrContent: content, qrcodeKey: key);
  }

  @override
  Future<QrPollResult> pollQr(String qrcodeKey) async {
    final res = await client.get(
      config.passportUrl(BiliPaths.qrPoll),
      query: {'qrcode_key': qrcodeKey, 'source': 'main-fe-header'},
    );
    // 原生端可从 Set-Cookie 直接拿到会话 Cookie（Web 端读不到，
    // 统一以 crossDomain URL 参数为准，见 QrPollResult.parseLoginCookies）
    await client.absorbSetCookies(res.headers['set-cookie']);
    return QrPollResult.parsePollData(_dataMap(res));
  }

  @override
  Future<BiliAccount?> fetchAccount() async {
    final res = await client.get(config.url(BiliPaths.nav));
    return BiliAccount.fromNavData(_dataMap(res));
  }

  static Map<String, dynamic> _dataMap(Response<dynamic> res) {
    final d = res.data;
    if (d is Map && d['data'] is Map) {
      return Map<String, dynamic>.from(d['data'] as Map);
    }
    return const {};
  }
}
