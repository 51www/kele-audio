import 'package:flutter/foundation.dart';

import '../api/key_value_store.dart';

/// 设置页持久化（M5）。
///
/// 目前只有「仅 Wi-Fi 下载」占位开关（下载能力 M8 实现，先把选择记住）；
/// 主题走 `ThemeController`，音质/播放模式/自动连播走 `PlayerPrefs`。
class SettingsStore extends ChangeNotifier {
  SettingsStore(this._kv);

  static const String keyWifiOnly = 'download_wifi_only';

  final KeyValueStore _kv;

  /// 仅 Wi-Fi 下载（默认开：移动网络省流优先）。
  bool get wifiOnlyDownload => _kv.getString(keyWifiOnly) != '0';

  Future<void> setWifiOnlyDownload(bool v) async {
    await _kv.setString(keyWifiOnly, v ? '1' : '0');
    notifyListeners();
  }
}
