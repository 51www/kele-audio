import '../../domain/album.dart';

/// 书架专辑的**轻量元数据快照**（备份用）。
///
/// 背景：`album` / `chapter` 属缓存表，不进备份白名单，换机/清空还原后
/// 书架只剩 `album_id`，卡片会退化成「未知专辑」且无法续播。这里只随备份
/// 携带重开所需的最小字段：
/// - 专辑：id / 标题 / UP 名 / 分类 / 封面 **URL** / 来源类型 / up_mid；
/// - 曲目：标题 / 时长 / 音源标识（bvid / cid）；
/// - 上次听到的章节与秒级进度。
///
/// 封面**不存图片二进制**：还原后由现有封面链按 URL 重取，失败走字母/渐变
/// 占位，避免备份体积膨胀。
class ShelfAlbumSnapshot {
  const ShelfAlbumSnapshot({
    required this.album,
    required this.chapters,
    this.lastChapterId = '',
    this.lastPositionSec = 0,
  });

  final Album album;
  final List<Chapter> chapters;
  final String lastChapterId;
  final int lastPositionSec;

  Map<String, dynamic> toJson() => {
    'album': album.toJson(),
    'chapters': [
      for (final c in chapters)
        {
          'id': c.id,
          'index': c.index,
          'title': c.title,
          'duration': c.durationSec,
          'bvid': c.bvid,
          'cid': c.cid,
        },
    ],
    'last_chapter_id': lastChapterId,
    'last_position_sec': lastPositionSec,
  };

  /// 单条宽容解析：字段缺失/类型不对返回 null，由调用方跳过。
  static ShelfAlbumSnapshot? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final albumRaw = raw['album'];
    if (albumRaw is! Map) return null;
    final Album album;
    try {
      album = Album.fromJson(Map<String, dynamic>.from(albumRaw));
    } catch (_) {
      return null;
    }
    if (album.id.isEmpty) return null;

    final chapters = <Chapter>[];
    final list = raw['chapters'];
    if (list is List) {
      for (final item in list) {
        if (item is! Map) continue;
        final j = Map<String, dynamic>.from(item);
        final index = (j['index'] as num?)?.toInt() ?? chapters.length;
        final id = '${j['id'] ?? ''}';
        chapters.add(Chapter(
          id: id.isEmpty ? Chapter.keyOf(album.id, index + 1) : id,
          albumId: album.id,
          index: index,
          title: '${j['title'] ?? ''}',
          durationSec: (j['duration'] as num?)?.toInt() ?? 0,
          bvid: '${j['bvid'] ?? ''}',
          cid: (j['cid'] as num?)?.toInt() ?? 0,
        ));
      }
    }
    return ShelfAlbumSnapshot(
      album: album,
      chapters: chapters,
      lastChapterId: '${raw['last_chapter_id'] ?? ''}',
      lastPositionSec: (raw['last_position_sec'] as num?)?.toInt() ?? 0,
    );
  }

  /// 数组解析：单条损坏只跳过该条，绝不让整个导入失败（兼容旧/坏备份）。
  static List<ShelfAlbumSnapshot> listFromJson(Object? raw) {
    if (raw is! List) return const [];
    final out = <ShelfAlbumSnapshot>[];
    for (final item in raw) {
      final snap = tryFromJson(item);
      if (snap != null) out.add(snap);
    }
    return out;
  }
}
