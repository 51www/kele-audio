import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../api/bili_client.dart';
import '../api/bili_login_api.dart';
import '../api/key_value_store.dart';

/// 扫码登录流程阶段（绑定页 UI 按此渲染）。
enum QrLoginPhase {
  /// 未开始 / 已停止
  idle,

  /// 二维码已生成，等待扫码
  waiting,

  /// 已扫码，等待手机确认
  scanned,

  /// 登录成功
  success,

  /// 二维码过期（可刷新重来）
  expired,

  /// 网络异常（可重试）
  error,
}

/// B 站账号绑定（M5 账号绑定）：绑定态 + 账号档案 + 扫码登录状态机。
///
/// - 绑定态单一事实源 = [BiliClient.isLoggedIn]（会话里是否有 SESSDATA）；
/// - 登录态仅存本地（PRD §7.6），档案缓存一份用于设置页即时展示；
/// - 轮询节奏 [pollInterval] 一次，连续失败 3 次转 [QrLoginPhase.error]
///   防呆刷（R2：不硬刷）。
class BiliAccountService extends ChangeNotifier {
  BiliAccountService({
    required this.client,
    required this.kv,
    QrLoginGateway? gateway,
    this.pollInterval = const Duration(seconds: 2),
    this.log,
  }) : _gateway = gateway ?? BiliLoginApi(client: client) {
    _restoreProfile();
  }

  /// 账号档案缓存 key（JSON：mid/uname/face）。
  static const String keyProfileCache = 'bili_account_profile';

  /// 连续轮询失败多少次后转 [QrLoginPhase.error]。
  static const int maxPollFailures = 3;

  final BiliClient client;
  final KeyValueStore kv;
  final QrLoginGateway _gateway;
  final Duration pollInterval;
  final void Function(String message)? log;

  Timer? _timer;
  bool _polling = false;
  int _pollFailures = 0;
  QrLoginPhase _phase = QrLoginPhase.idle;
  String? _qrContent;
  String? _error;
  BiliAccount? _account;

  /// 是否已绑定（会话里有 SESSDATA）。
  bool get bound => client.isLoggedIn;

  /// 大会员是否生效中（档案缓存为准，nav 校准后更新）。
  bool get isVip => _account?.isVip ?? false;

  /// 已绑定账号档案（缓存优先，进页时后台校准）。
  BiliAccount? get account => _account;

  QrLoginPhase get qrPhase => _phase;

  /// 待渲染成二维码的登录链接。
  String? get qrContent => _qrContent;

  /// [QrLoginPhase.error] 时的提示文案。
  String? get qrError => _error;

  void _restoreProfile() {
    final raw = kv.getString(keyProfileCache);
    if (raw == null || raw.isEmpty) return;
    try {
      _account = BiliAccount.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // 缓存损坏直接丢弃，下次拉取重建
    }
  }

  /// 开始一轮扫码登录：生成二维码并定时轮询。
  Future<void> startQrLogin() async {
    stopQrLogin();
    _pollFailures = 0;
    _error = null;
    try {
      final ticket = await _gateway.generateQr();
      _qrContent = ticket.qrContent;
      _phase = QrLoginPhase.waiting;
      _timer = Timer.periodic(
        pollInterval,
        (_) => unawaited(pollOnce(ticket.qrcodeKey)),
      );
    } catch (e) {
      log?.call('[account] qr generate failed: $e');
      _phase = QrLoginPhase.error;
      _error = '二维码获取失败，请检查网络后重试';
    }
    notifyListeners();
  }

  /// 立即轮询一次（定时器与单测共用；重入保护）。
  @visibleForTesting
  Future<void> pollOnce(String qrcodeKey) async {
    if (_polling) return;
    _polling = true;
    try {
      final result = await _gateway.pollQr(qrcodeKey);
      _pollFailures = 0;
      switch (result.status) {
        case QrScanStatus.waiting:
          _phase = QrLoginPhase.waiting;
        case QrScanStatus.scanned:
          _phase = QrLoginPhase.scanned;
        case QrScanStatus.expired:
          _phase = QrLoginPhase.expired;
          stopQrLogin();
        case QrScanStatus.success:
          _phase = QrLoginPhase.success;
          stopQrLogin();
          await client.acceptLoginCookies(result.cookies);
          await refreshProfile();
      }
    } catch (e) {
      _pollFailures++;
      log?.call('[account] poll failed ($_pollFailures): $e');
      if (_pollFailures >= maxPollFailures) {
        _phase = QrLoginPhase.error;
        _error = '网络异常，请检查网络后重试';
        stopQrLogin();
      }
    } finally {
      _polling = false;
    }
    notifyListeners();
  }

  /// 停止轮询（离开页面时调用；不改阶段）。
  void stopQrLogin() {
    _timer?.cancel();
    _timer = null;
  }

  /// 校准登录态与档案：会话有效则更新档案缓存，nav 明确回报未登录则就地解绑。
  ///
  /// 网络失败保持现状（缓存档案继续显示），不误判解绑。
  Future<void> refreshProfile() async {
    try {
      final account = await _gateway.fetchAccount();
      if (account == null) {
        await logout();
        return;
      }
      _account = account;
      await kv.setString(keyProfileCache, jsonEncode(account.toJson()));
    } catch (e) {
      log?.call('[account] refresh profile failed: $e');
    }
    notifyListeners();
  }

  /// 解除绑定：清会话 Cookie（设备指纹保留，见 [BiliClient.logout]）与档案缓存。
  Future<void> logout() async {
    stopQrLogin();
    _phase = QrLoginPhase.idle;
    _qrContent = null;
    _account = null;
    await client.logout();
    await kv.remove(keyProfileCache);
    notifyListeners();
  }
}
