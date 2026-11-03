import '../../api/bili_client.dart';
import '../../data/local_database.dart';
import '../../data/table.dart';
import '../offline/offline_cache_service.dart';
import '../player/progress_store.dart';
import '../settings_store.dart';

/// 备份白名单（设计原则 1）：**只导出/导入这里声明的 key**，
/// 绝不整库序列化 —— 缓存（album/chapter/发现页）、离线下载文件、
/// 设备指纹（buvid）等一律不参与迁移。
class BackupWhitelist {
  BackupWhitelist._();

  /// 设置类 KV（字符串值）。owner：SettingsStore / PlayerPrefs /
  /// OfflineCacheService / ThemeController。
  ///
  /// ThemeController 在 app 层（按层不反向引用），其 key 在此字面量固化
  /// （与原 WebDAV 同步集同一口径，见 ThemeController.presetKey/childrenKey）。
  static const List<({String key, String label})> settingsItems = [
    (key: SettingsStore.keyWifiOnly, label: '仅 Wi-Fi 下载'),
    (key: SettingsStore.keyFeaturedVisible, label: '发现页「编辑精选」显隐'),
    (key: SettingsStore.keyHiddenCategories, label: '发现页分类显隐'),
    (key: PlayerPrefs.keyRate, label: '默认倍速'),
    (key: PlayerPrefs.keyMode, label: '默认播放模式'),
    (key: PlayerPrefs.keyQuality, label: '默认音质'),
    (key: PlayerPrefs.keyStopAtChapterEnd, label: '「本章结束即停」'),
    (key: PlayerPrefs.keyAutoNext, label: '后台自动播放下一章'),
    (key: OfflineCacheService.keyOnlyCached, label: '「仅播放已缓存」'),
    (key: 'theme_preset', label: '主题皮肤'),
    (key: 'children_mode', label: '儿童模式'),
  ];

  /// 参与备份的表（引用 [LocalDatabase] 实例上的同一批 [Table] 对象，
  /// 不含 album/chapter 缓存表与 download 任务表）。
  static List<Table<dynamic>> tablesOf(LocalDatabase db) =>
      [db.shelf, db.playHistory, db.playLogs];

  /// 表 key（`t_*`）→ 中文 label（确认框展示用）。
  static const Map<String, String> tableLabels = {
    'shelf': '书架收藏',
    'play_history': '收听历史与进度',
    'play_log': '收听统计',
  };

  /// 敏感字段（登录态等）：单独放 payload.secure，导出前可评估是否携带。
  /// 登录态属用户自己的凭据，随备份迁移可省去换机后重扫。
  static const List<({String key, String label})> secureItems = [
    (key: BiliClient.prefCookie, label: 'B 站登录态'),
  ];
}
