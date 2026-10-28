import 'package:flutter/foundation.dart';

import '../api/key_value_store.dart';

/// 设置页持久化（M5）。
///
/// - 「仅 Wi-Fi 下载」占位开关（下载能力 M8 实现，先把选择记住）；
/// - 发现页显示控制（高级设置）：编辑精选行显隐 + 分类显隐；
/// - 主题走 `ThemeController`，音质/播放模式/自动连播走 `PlayerPrefs`。
class SettingsStore extends ChangeNotifier {
  SettingsStore(this._kv);

  static const String keyWifiOnly = 'download_wifi_only';

  /// 发现页「编辑精选」一行是否显示（默认显示）。
  static const String keyFeaturedVisible = 'discover_featured_visible';

  /// 发现页被隐藏的分类 id 集合（逗号分隔持久化，空 = 全部显示）。
  static const String keyHiddenCategories = 'discover_hidden_categories';

  /// 发现页固定显示的分类（「推荐」）：不参与显隐配置，恒显示。
  static const String pinnedCategoryId = 'rec';

  final KeyValueStore _kv;

  /// 仅 Wi-Fi 下载（默认开：移动网络省流优先）。
  bool get wifiOnlyDownload => _kv.getString(keyWifiOnly) != '0';

  Future<void> setWifiOnlyDownload(bool v) async {
    await _kv.setString(keyWifiOnly, v ? '1' : '0');
    notifyListeners();
  }

  /// 发现页「编辑精选」一行是否显示（默认显示）。
  bool get featuredVisible => _kv.getString(keyFeaturedVisible) != '0';

  Future<void> setFeaturedVisible(bool v) async {
    await _kv.setString(keyFeaturedVisible, v ? '1' : '0');
    notifyListeners();
  }

  /// 被隐藏的分类 id（有序去重）。
  Set<String> get hiddenCategoryIds {
    final raw = _kv.getString(keyHiddenCategories) ?? '';
    return {
      for (final id in raw.split(','))
        if (id.trim().isNotEmpty) id.trim(),
    };
  }

  /// 分类是否在发现页显示；[pinnedCategoryId]（「推荐」）恒为 true。
  bool isCategoryVisible(String id) =>
      id == pinnedCategoryId || !hiddenCategoryIds.contains(id);

  /// 设置分类显隐。[pinnedCategoryId] 不参与配置，调用直接忽略。
  Future<void> setCategoryVisible(String id, bool visible) async {
    if (id == pinnedCategoryId) return;
    final hidden = hiddenCategoryIds;
    if (visible) {
      hidden.remove(id);
    } else {
      hidden.add(id);
    }
    await _kv.setString(keyHiddenCategories, hidden.join(','));
    notifyListeners();
  }

  /// 外部写入 KV 后（如 WebDAV 同步恢复）通知设置页刷新。
  void notifyChanged() => notifyListeners();
}
