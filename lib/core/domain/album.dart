/// 专辑与章节实体（PRD §7.5）。
///
/// 播放地址（DASH URL）**永不落库**：持久化层只存 bvid / cid，
/// 播放时实时取址、只存内存（见 AGENT.md 技术决策）。
library;

/// 章节来源：多 P 视频 / 合集（系列）。
enum SourceType { multiPart, series }

extension SourceTypeX on SourceType {
  String get wire => this == SourceType.multiPart ? 'multi_part' : 'series';

  static SourceType fromWire(String? v) =>
      v == 'series' ? SourceType.series : SourceType.multiPart;
}

/// 专辑（一张「有声书 / 相声专辑」＝ 一个视频合集或多 P 视频）。
class Album {
  const Album({
    required this.id,
    required this.sourceType,
    required this.title,
    required this.coverUrl,
    required this.upName,
    required this.chapterCount,
    required this.categoryId,
    this.bvid = '',
    this.upMid = 0,
    this.intro = '',
    this.totalDurationSec = 0,
    this.playCount = 0,
    this.createdAt = 0,
  });

  /// 本地主键：`bvid`（多 P）或 `season/series id`（合集）。
  final String id;
  final SourceType sourceType;
  final String title;
  final String coverUrl;
  final String upName;
  final int chapterCount;
  final String categoryId;

  /// 多 P 视频的 bvid；合集为空。
  final String bvid;
  final int upMid;
  final String intro;
  final int totalDurationSec;
  final int playCount;
  final int createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'source_type': sourceType.wire,
        'title': title,
        'cover_url': coverUrl,
        'up_name': upName,
        'chapter_count': chapterCount,
        'category_id': categoryId,
        'bvid': bvid,
        'up_mid': upMid,
        'intro': intro,
        'total_duration_sec': totalDurationSec,
        'play_count': playCount,
        'created_at': createdAt,
      };

  /// 封面地址归一：兼容历史数据里的协议相对地址（`//`）与明文 HTTP。
  /// 见 `core/api/discover_source.dart` 的 `normalizePic`（入库前同口径）。
  static String normalizeCover(String raw) {
    final p = raw.trim();
    if (p.isEmpty) return '';
    if (p.startsWith('//')) return 'https:$p';
    if (p.startsWith('http://')) return p.replaceFirst('http://', 'https://');
    return p;
  }

  factory Album.fromJson(Map<String, dynamic> j) => Album(
        id: '${j['id'] ?? ''}',
        sourceType: SourceTypeX.fromWire('${j['source_type'] ?? ''}'),
        title: '${j['title'] ?? ''}',
        coverUrl: normalizeCover('${j['cover_url'] ?? ''}'),
        upName: '${j['up_name'] ?? ''}',
        chapterCount: (j['chapter_count'] as num?)?.toInt() ?? 0,
        categoryId: '${j['category_id'] ?? ''}',
        bvid: '${j['bvid'] ?? ''}',
        upMid: (j['up_mid'] as num?)?.toInt() ?? 0,
        intro: '${j['intro'] ?? ''}',
        totalDurationSec: (j['total_duration_sec'] as num?)?.toInt() ?? 0,
        playCount: (j['play_count'] as num?)?.toInt() ?? 0,
        createdAt: (j['created_at'] as num?)?.toInt() ?? 0,
      );

  /// 局部替换（M3：详情页/发现页把列表接口缺的字段补齐后再入库）。
  Album copyWith({
    int? chapterCount,
    String? title,
    String? upName,
    String? coverUrl,
    String? intro,
    int? upMid,
    int? totalDurationSec,
    int? playCount,
  }) =>
      Album(
        id: id,
        sourceType: sourceType,
        title: title ?? this.title,
        coverUrl: coverUrl ?? this.coverUrl,
        upName: upName ?? this.upName,
        chapterCount: chapterCount ?? this.chapterCount,
        categoryId: categoryId,
        bvid: bvid,
        upMid: upMid ?? this.upMid,
        intro: intro ?? this.intro,
        totalDurationSec: totalDurationSec ?? this.totalDurationSec,
        playCount: playCount ?? this.playCount,
        createdAt: createdAt,
      );
}

/// 章节（多 P 的一个分 P，或合集里的一个视频）。
class Chapter {
  const Chapter({
    required this.id,
    required this.albumId,
    required this.index,
    required this.title,
    required this.durationSec,
    this.bvid = '',
    this.cid = 0,
  });

  /// 本地主键：`{albumId}:{cid}`。
  final String id;
  final String albumId;
  final int index;
  final String title;
  final int durationSec;
  final String bvid;
  final int cid;

  Map<String, dynamic> toJson() => {
        'id': id,
        'album_id': albumId,
        'index': index,
        'title': title,
        'duration': durationSec,
        'bvid': bvid,
        'cid': cid,
      };

  factory Chapter.fromJson(Map<String, dynamic> j) => Chapter(
        id: '${j['id'] ?? ''}',
        albumId: '${j['album_id'] ?? ''}',
        index: (j['index'] as num?)?.toInt() ?? 0,
        title: '${j['title'] ?? ''}',
        durationSec: (j['duration'] as num?)?.toInt() ?? 0,
        bvid: '${j['bvid'] ?? ''}',
        cid: (j['cid'] as num?)?.toInt() ?? 0,
      );

  static String keyOf(String albumId, int cid) => '$albumId:$cid';

  /// 补齐 cid（合集/系列章节首次解析成功后回写）
  Chapter copyWith({int? cid, int? index, String? title, int? durationSec}) =>
      Chapter(
        id: id,
        albumId: albumId,
        index: index ?? this.index,
        title: title ?? this.title,
        durationSec: durationSec ?? this.durationSec,
        bvid: bvid,
        cid: cid ?? this.cid,
      );
}
