/// 离线音频存储抽象（M8 / PRD §5.8）。
///
/// 键 → 音频字节 的持久化存储。`key` 约定为章节 id（`albumId:cid`）。
/// 平台实现见 `audio_store.dart` 的条件导出（IO 文件 / Web IndexedDB）。
library;

abstract class AudioStore {
  /// 保存音频字节，返回可播放地址（`file:` / `blob:`）。
  /// 失败抛异常，由调用方标记任务失败。
  Future<String> save(String key, List<int> bytes);

  /// 删除一条缓存（不存在时静默成功）。返回是否确实删除了数据。
  Future<bool> delete(String key);

  /// 已缓存字节的**可播放地址**；未缓存返回 null。
  Future<String?> playableUrl(String key);

  /// 已缓存的字节数（未缓存为 0）。
  Future<int> sizeOf(String key);

  /// 清空全部缓存（「全部清理」用）。
  Future<void> clearAll();

  /// 存储位置描述（设置/缓存页展示用）。
  String get locationLabel;
}
