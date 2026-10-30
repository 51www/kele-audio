import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const String _kUpdateChannel = 'com.kele.audio/update';

/// Android 安装链路封装（提示词 2「Android 安装链路」）。
///
/// 三个 MethodChannel 方法对应原生端实现：
///   - `canRequestInstall`：当前是否可请求「安装未知应用」权限（API 26+）。
///   - `openInstallPermission`：跳系统设置授权页。
///   - `installApk`：FileProvider 转 URI + ACTION_VIEW 拉起安装。
///
/// 非 Android 平台方法安全降级（返回 false / 无操作 / 抛 [UnsupportedError]），
/// 由调用方保证不会走到安装分支。
class UpdateInstaller {
  UpdateInstaller([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel(_kUpdateChannel);

  final MethodChannel _channel;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 当前是否可请求「安装未知应用」权限。非 Android 返回 false。
  Future<bool> canRequestInstall() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('canRequestInstall') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// 跳系统设置授权「安装未知应用」页。非 Android 无操作。
  Future<void> openInstallPermission() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('openInstallPermission');
    } on PlatformException {
      // 忽略：用户可手动前往设置
    }
  }

  /// 拉起安装。非 Android 抛 [UnsupportedError]（UI 不应走到这）。
  Future<void> installApk(String filePath) async {
    if (!_isAndroid) {
      throw UnsupportedError('installApk only supported on Android');
    }
    await _channel.invokeMethod<void>('installApk', <String, dynamic>{
      'path': filePath,
    });
  }
}

/// 安装结果（供 UI 决定下一步）。
enum InstallResult {
  /// 已拉起系统安装器。
  installing,
  /// 需要先去系统设置授予「安装未知应用」权限。
  needsPermission,
}
