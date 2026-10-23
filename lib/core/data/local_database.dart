import 'dart:convert';

import '../api/key_value_store.dart';
import '../domain/album.dart';
import '../domain/records.dart';
import 'table.dart';

/// 建表结果（M1 准出证据之一）。
class DbCreateResult {
  const DbCreateResult({
    required this.created,
    required this.version,
    required this.tables,
    required this.createdAtMs,
  });

  final bool created;
  final int version;
  final List<String> tables;
  final int createdAtMs;

  String get describe {
    final at = DateTime.fromMillisecondsSinceEpoch(createdAtMs);
    final stamp =
        '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')} '
        '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    return '${created ? '首次建表成功' : '表已存在'} · schema v$version · '
        '${tables.length} 张表（${tables.join(', ')}）· $stamp';
  }

  Map<String, dynamic> toJson() => {
        'schema_version': version,
        'created_at': createdAtMs,
        'tables': tables,
      };
}

/// 本地数据库门面：PRD §7.5 的六张表。
///
/// - 表存储：`shared_preferences` JSON（见 AGENT.md 技术决策，MVP 不引数据库）；
/// - [ensureCreated]：幂等建表 + 写入 schema 元信息；
/// - 领域查询走 `lib/core/data/daos.dart` 里的 DAO。
class LocalDatabase {
  LocalDatabase(this.kv) {
    albums = Table<Album>(
      name: 'album',
      kv: kv,
      encode: (r) => r.toJson(),
      decode: Album.fromJson,
      idOf: (r) => r.id,
    );
    chapters = Table<Chapter>(
      name: 'chapter',
      kv: kv,
      encode: (r) => r.toJson(),
      decode: Chapter.fromJson,
      idOf: (r) => r.id,
    );
    shelf = Table<ShelfItem>(
      name: 'shelf',
      kv: kv,
      encode: (r) => r.toJson(),
      decode: ShelfItem.fromJson,
      idOf: (r) => r.albumId,
    );
    playHistory = Table<PlayHistory>(
      name: 'play_history',
      kv: kv,
      encode: (r) => r.toJson(),
      decode: PlayHistory.fromJson,
      idOf: (r) => '${r.albumId}|${r.chapterId}',
    );
    playLogs = Table<PlayLogEntry>(
      name: 'play_log',
      kv: kv,
      encode: (r) => r.toJson(),
      decode: PlayLogEntry.fromJson,
      idOf: (r) => '${r.date}|${r.albumId}',
    );
    downloads = Table<DownloadTask>(
      name: 'download',
      kv: kv,
      encode: (r) => r.toJson(),
      decode: DownloadTask.fromJson,
      idOf: (r) => r.chapterId,
    );
  }

  static const int schemaVersion = 1;
  static const String metaKey = 'db_meta';

  /// PRD §7.5 六张表
  static const List<String> tableNames = [
    'album',
    'chapter',
    'shelf',
    'play_history',
    'play_log',
    'download',
  ];

  final KeyValueStore kv;

  late final Table<Album> albums;
  late final Table<Chapter> chapters;
  late final Table<ShelfItem> shelf;
  late final Table<PlayHistory> playHistory;
  late final Table<PlayLogEntry> playLogs;
  late final Table<DownloadTask> downloads;

  DbCreateResult? _createResult;
  DbCreateResult? get createResult => _createResult;

  List<Table<dynamic>> get _allTables =>
      [albums, chapters, shelf, playHistory, playLogs, downloads];

  /// 幂等建表：首次写入 schema 元信息，之后只做加载。
  Future<DbCreateResult> ensureCreated() async {
    if (_createResult != null) return _createResult!;

    final raw = kv.getString(metaKey);
    DbCreateResult result;
    var created = false;
    if (raw == null || raw.trim().isEmpty) {
      created = true;
      result = DbCreateResult(
        created: true,
        version: schemaVersion,
        tables: tableNames,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await kv.setString(metaKey, jsonEncode(result.toJson()));
    } else {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final tables = (map['tables'] as List?)
              ?.map((e) => '$e')
              .toList() ??
          tableNames;
      result = DbCreateResult(
        created: false,
        version: (map['schema_version'] as num?)?.toInt() ?? schemaVersion,
        tables: tables,
        createdAtMs: (map['created_at'] as num?)?.toInt() ?? 0,
      );
    }

    for (final t in _allTables) {
      await t.load();
    }
    // 缺表补齐（升级场景：老版本少表）
    if (!created) {
      final known =
          (jsonDecode(kv.getString(metaKey) ?? '{}') as Map<String, dynamic>);
      final existing =
          (known['tables'] as List?)?.map((e) => '$e').toSet() ?? <String>{};
      final missing = tableNames.where((t) => !existing.contains(t)).toList();
      if (missing.isNotEmpty) {
        known['tables'] = [...existing, ...missing];
        await kv.setString(metaKey, jsonEncode(known));
        result = DbCreateResult(
          created: false,
          version: schemaVersion,
          tables: (known['tables'] as List).map((e) => '$e').toList(),
          createdAtMs: (known['created_at'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
        );
      }
    }

    _createResult = result;
    return result;
  }

  /// 各表行数（自检面板展示）。
  Future<Map<String, int>> counts() async {
    await ensureCreated();
    return {
      for (final t in _allTables) t.name: t.count,
    };
  }

  /// 清空全部数据（设置页「清除本地数据」预留）。
  Future<void> wipe() async {
    for (final t in _allTables) {
      await t.clear();
    }
    await kv.remove(metaKey);
    _createResult = null;
  }
}
