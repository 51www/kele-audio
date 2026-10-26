import '../../api/key_value_store.dart';
import '../../data/daos.dart';
import '../../domain/playback.dart';
import '../../domain/records.dart';

/// 播放进度持久化（M2 任务 6 → **P-03 断点续播 / P-04 跨章续播**）。
///
/// 写入时机（PRD §5.4.2）：
/// - 播放中每 **15s** 落一次盘（15~30s 区间的下沿，节流在 `PlayerService`）；
/// - 暂停 / 拖动进度 / 切章 / 睡眠定时到点 / 退后台 → **立即 flush**；
/// - 冷启动读 [lastOverall] 恢复「专辑 + 章节 + 秒级进度」。
///
/// 同时顺带维护 `shelf` 的收听字段（M4 书架「在听置顶区」直接可用）
/// 与 `play_log` 埋点（M8 听书统计的数据源）。
class ProgressStore {
  ProgressStore(this._daos);

  final Daos _daos;

  /// 写一条进度：`play_history` 主键是 `albumId|chapterId`，同章覆盖。
  Future<void> save({
    required String albumId,
    required String chapterId,
    required String chapterTitle,
    required int positionSec,
    required int durationSec,
  }) =>
      _daos.playHistory.put(PlayHistory(
        albumId: albumId,
        chapterId: chapterId,
        chapterTitle: chapterTitle,
        positionSec: positionSec,
        durationSec: durationSec,
        playedAt: DateTime.now().millisecondsSinceEpoch,
      ));

  /// 专辑内最后一次收听（**P-04：重进专辑定位到最后听的章节**）
  PlayHistory? lastOfAlbum(String albumId) =>
      _daos.playHistory.latestOfAlbum(albumId);

  /// 全局最后一次收听（**P-03：冷启动恢复**）
  PlayHistory? lastOverall() => _daos.playHistory.recent(limit: 1).firstOrNull;

  /// 已加入书架的专辑同步收听进度（书架卡片显示「已听 12/86」）
  Future<void> touchShelf({
    required String albumId,
    required String chapterId,
    required int positionSec,
    required int totalChapters,
  }) =>
      _daos.shelf.touch(
        albumId: albumId,
        chapterId: chapterId,
        positionSec: positionSec,
        totalChapters: totalChapters,
      );

  /// 收听时长埋点（M8 统计的数据源，M2 先落 `play_log`）
  Future<void> addPlaySeconds({
    required String albumId,
    required String categoryId,
    required int seconds,
  }) async {
    if (seconds <= 0 || albumId.isEmpty) return;
    final now = DateTime.now();
    final date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final existing = _daos.playLogs
        .byDate(date)
        .where((e) => e.albumId == albumId)
        .firstOrNull;
    await _daos.playLogs.add(PlayLogEntry(
      date: date,
      albumId: albumId,
      categoryId: categoryId.isEmpty
          ? existing?.categoryId ?? ''
          : categoryId,
      durationSec: (existing?.durationSec ?? 0) + seconds,
    ));
  }
}

/// 播放参数持久化（**P-08：倍速重启后保留**；音质与播放模式同理）。
///
/// `KeyValueStore` 只有字符串接口（CLI/测试可用内存实现），数字统一转字符串。
class PlayerPrefs {
  PlayerPrefs(this._kv);

  static const String keyRate = 'player_rate';
  static const String keyMode = 'player_mode';
  static const String keyQuality = 'player_quality';
  static const String keyStopAtChapterEnd = 'player_stop_at_chapter_end';

  /// M5 设置页「后台自动播放下一章」（PRD §5.6.4）；默认开（连播是听书主场景）。
  static const String keyAutoNext = 'player_auto_next';

  final KeyValueStore _kv;

  /// 倍速（0.5~3.0）；缺省 1.0（PRD 开放问题 Q3 采纳：**持久化倍速**）
  double get rate {
    final v = double.tryParse(_kv.getString(keyRate) ?? '');
    if (v == null || v < 0.5 || v > 3.0) return 1.0;
    return v;
  }

  Future<void> saveRate(double v) => _kv.setString(keyRate, '$v');

  PlayMode get mode => PlayModeX.fromWire(_kv.getString(keyMode));

  Future<void> saveMode(PlayMode mode) => _kv.setString(keyMode, mode.wire);

  AudioQuality get quality => AudioQuality.fromWire(_kv.getString(keyQuality));

  Future<void> saveQuality(AudioQuality q) => _kv.setString(keyQuality, q.wire);

  /// 「本章结束即停」：睡眠定时的独立开关（abts 同款）
  bool get stopAtChapterEnd => _kv.getString(keyStopAtChapterEnd) == '1';

  Future<void> saveStopAtChapterEnd(bool v) =>
      _kv.setString(keyStopAtChapterEnd, v ? '1' : '0');

  /// 「后台自动播放下一章」：关闭后本章播完即停（PRD §5.6.4 设置项）。
  /// 缺省开启：老数据无此 key 时保持连播行为不变。
  bool get autoNext => _kv.getString(keyAutoNext) != '0';

  Future<void> saveAutoNext(bool v) => _kv.setString(keyAutoNext, v ? '1' : '0');
}
