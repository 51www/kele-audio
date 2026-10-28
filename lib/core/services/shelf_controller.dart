import 'package:flutter/foundation.dart';

import '../data/daos.dart';
import '../domain/album.dart';
import '../domain/records.dart';

/// 书架视图模型（M4）：把 `shelf` 表与 `album` / `play_history` 联合成 UI 直接用的结构。
///
/// 兼作**收藏状态的单一事实源**（[ChangeNotifier]）：详情页 / 播放页的
/// 「加入 / 取消书架」都走这里，书架页 [watch] 它即可实时刷新，避免各页面
/// 各读各的 `ShelfDao` 导致状态不一致。
///
/// 数据全部在本地（shared_preferences JSON），无账号同步。
class ShelfController extends ChangeNotifier {
  ShelfController(this._daos);

  final Daos _daos;

  /// 已收藏的 albumId 集合（内存缓存，[ensure] 时装载）。
  final Set<String> _ids = {};
  bool _loaded = false;

  /// 幂等装载：把已收藏的 albumId 读进内存，后续 [has] 走内存、O(1)。
  Future<void> ensure() async {
    await _daos.db.ensureCreated();
    if (_loaded) return;
    _ids.clear();
    for (final s in _daos.shelf.list()) {
      _ids.add(s.albumId);
    }
    _loaded = true;
  }

  /// 同步恢复后强制重载（[ensure] 幂等不会自动重读）。
  Future<void> reload() async {
    _loaded = false;
    await ensure();
    notifyListeners();
  }

  /// 是否已收藏（UI 直接读，无需 async）。
  bool has(String albumId) => _ids.contains(albumId);

  /// 播放进度落盘后由 [PlayerService] 调用，通知书架页刷新
  /// 「在听置顶区 / 已听 x/y」。没有订阅者时是安全的空操作。
  void notifyProgressChanged() => notifyListeners();

  /// 加入 / 取消（详情页、播放页的收藏按钮）。
  Future<void> toggle(String albumId) async {
    await ensure();
    if (_ids.contains(albumId)) {
      await _daos.shelf.remove(albumId);
      _ids.remove(albumId);
    } else {
      await _daos.shelf.add(albumId);
      _ids.add(albumId);
    }
    notifyListeners();
  }

  /// 仅加入（[remove] 的逆操作），幂等。
  Future<void> add(String albumId) async {
    await ensure();
    if (_ids.add(albumId)) {
      await _daos.shelf.add(albumId);
      notifyListeners();
    }
  }

  /// 仅移除（左滑 / 多选删除），幂等。
  Future<void> remove(String albumId) async {
    await ensure();
    if (_ids.remove(albumId)) {
      await _daos.shelf.remove(albumId);
      notifyListeners();
    }
  }

  /// 批量移除（多选删除）。
  Future<void> removeAll(Iterable<String> albumIds) async {
    await ensure();
    var changed = false;
    for (final id in albumIds) {
      if (_ids.remove(id)) {
        await _daos.shelf.remove(id);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// 整条还原（左滑删除后的「撤销」：保留原进度字段）。
  Future<void> restore(ShelfItem item) async {
    await ensure();
    await _daos.shelf.upsertItem(item);
    _ids.add(item.albumId);
    notifyListeners();
  }

  List<ShelfItem> get items => _daos.shelf.list();

  /// 联合查询（**M4 书架页核心**）：shelf × album × play_history。
  ///
  /// 每次同步读取内存表，返回 [ShelfView] 列表（默认按最近收听排序）。
  /// 书架页每次 build 都调用，保证切回页面时读到的进度是最新的。
  List<ShelfView> buildViews() {
    final now = DateTime.now();
    final views = <ShelfView>[];
    for (final item in _daos.shelf.list()) {
      final album = _daos.albums.get(item.albumId);
      final finished = _daos.playHistory.finishedCount(item.albumId);
      // 总章节数口径：DB 里的真实章节数 > 播放时记录的总数 > 列表接口的 chapterCount。
      // （列表接口的 chapterCount 常与真实分 P 数不符，不能作为「已听 x/y」分母）
      final dbChapters = _daos.chapters.countFor(item.albumId);
      final total = dbChapters > 0
          ? dbChapters
          : (item.totalChapters > 0
              ? item.totalChapters
              : album?.chapterCount ?? 0);

      // 「在听」：30 天内有收听记录，且还没听完。
      final lastPlayed = item.lastPlayedAt > 0
          ? DateTime.fromMillisecondsSinceEpoch(item.lastPlayedAt)
          : null;
      final inListening = lastPlayed != null &&
          now.difference(lastPlayed) <= const Duration(days: 30) &&
          finished < total;

      // 在听进度条：取最后一次收听章节的百分比（无则 0）。
      final lastPercent = item.lastChapterId.isEmpty
          ? 0
          : (_daos.playHistory
                  .forChapter(item.albumId, item.lastChapterId)
                  ?.percent ??
              0);

      views.add(ShelfView(
        item: item,
        album: album,
        finishedCount: finished,
        totalChapters: total,
        inListening: inListening,
        lastChapterPercent: lastPercent,
      ));
    }
    return views;
  }
}

/// 书架卡片视图模型：专辑信息 + 收听进度 + 是否「在听」。
///
/// 纯数据，不依赖 Flutter（单测可直接构造）。
class ShelfView {
  const ShelfView({
    required this.item,
    required this.album,
    required this.finishedCount,
    required this.totalChapters,
    required this.inListening,
    required this.lastChapterPercent,
  });

  final ShelfItem item;
  final Album? album;

  /// 已听完的章节数（书架卡片「已听 12/86」的分子）
  final int finishedCount;

  /// 专辑总章节数（分母）：shelf 里记的优先，缺失时回退专辑自带 chapterCount
  final int totalChapters;

  /// 30 天内有收听且未听完 → 进「在听置顶区」
  final bool inListening;

  /// 最后一次收听章节的进度百分比（0~100，在听置顶区进度条用）
  final int lastChapterPercent;

  /// 已听完章节占比（0~1）
  double get finishedRatio =>
      totalChapters <= 0 ? 0 : (finishedCount / totalChapters).clamp(0.0, 1.0);

  /// 收藏时间（缺省用创建时间）
  int get collectedAt => item.createdAt;

  /// 最近收听时间（未收听过时回退到收藏时间）
  int get lastPlayedAt =>
      item.lastPlayedAt > 0 ? item.lastPlayedAt : item.createdAt;

  /// 标题（专辑缺失时给兜底，避免书架出现空白卡片）
  String get title => album?.title ?? '未知专辑';

  /// UP 主（专辑缺失或为空时兜底）
  String get upName {
    final name = album?.upName;
    return (name == null || name.isEmpty) ? 'UP 主未知' : name;
  }

  /// 封面（专辑缺失时兜底空串 → UI 走字母渐变占位）
  String get coverUrl => album?.coverUrl ?? '';
}
