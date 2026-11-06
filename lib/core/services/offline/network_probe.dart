import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 当前网络类型（下载门控用）。
///
/// 只区分「是否 Wi-Fi」，不用于统计或其它业务。
enum NetworkKind {
  wifi,

  /// 有线网络（等同 Wi-Fi，不拦截）。
  ethernet,

  /// 蜂窝移动网络。
  mobile,

  /// 无网络连接。
  none,

  /// 无法判断（Web / 非 Android / 原生通道异常）。
  unknown,
}

/// 网络类型探测（抽象便于单测注入固定结果）。
abstract class NetworkProbe {
  Future<NetworkKind> current();
}

/// 系统网络探测：走项目自建的原生 MethodChannel（`com.kele.audio/network`）。
///
/// Android 端使用 ConnectivityManager + 已有 `ACCESS_NETWORK_STATE` 权限
/// （Manifest 早已声明），不引入新依赖、不新增权限申请；
/// Web / 其它平台无可靠能力，统一返回 [NetworkKind.unknown]。
class PlatformNetworkProbe implements NetworkProbe {
  const PlatformNetworkProbe();

  static const MethodChannel _channel =
      MethodChannel('com.kele.audio/network');

  @override
  Future<NetworkKind> current() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return NetworkKind.unknown;
    }
    try {
      final raw = await _channel.invokeMethod<String>('type');
      return switch (raw) {
        'wifi' => NetworkKind.wifi,
        'ethernet' => NetworkKind.ethernet,
        'mobile' => NetworkKind.mobile,
        'none' => NetworkKind.none,
        _ => NetworkKind.unknown,
      };
    } catch (_) {
      // 通道不可用 / ROM 限制：按未知处理，交由下载门控决定降级策略。
      return NetworkKind.unknown;
    }
  }
}
