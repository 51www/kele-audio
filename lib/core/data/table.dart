import 'dart:convert';

import '../api/key_value_store.dart';

/// 一张「表」＝ 一个 SharedPreferences key 下的 JSON 数组。
///
/// AGENT.md 技术决策：MVP 不引数据库，本地存储用 `shared_preferences`（JSON）
/// （abts 同款，实测够用）。这里用 [Table] 把「建表 / 增删改查 / 落盘」收敛成
/// 统一门面，DAO 在其上做领域查询，后续要换 drift 只动这层。
class Table<T> {
  Table({
    required this.name,
    required this.kv,
    required this.encode,
    required this.decode,
    required this.idOf,
  });

  /// 表名（PRD §7.5）
  final String name;
  final KeyValueStore kv;

  final Map<String, dynamic> Function(T row) encode;
  final T Function(Map<String, dynamic> json) decode;
  final String Function(T row) idOf;

  static String storageKey(String tableName) => 't_$tableName';

  List<T>? _rows;

  bool get loaded => _rows != null;

  int get count => _rows?.length ?? 0;

  /// 幂等加载：表不存在时返回空表（建表前不会崩）。
  Future<void> load() async {
    if (_rows != null) return;
    final raw = kv.getString(storageKey(name));
    if (raw == null || raw.trim().isEmpty) {
      _rows = <T>[];
      return;
    }
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      _rows = list
          .map((e) => decode(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      // 数据损坏按空表处理（R8：坏数据不能把应用拖死）
      _rows = <T>[];
    }
  }

  Future<void> _flush() async {
    final rows = _rows ?? <T>[];
    await kv.setString(
      storageKey(name),
      jsonEncode(rows.map(encode).toList()),
    );
  }

  /// 内存快照（需先 [load]）。
  List<T> all() => List<T>.unmodifiable(_rows ?? <T>[]);

  T? byId(String id) {
    final rows = _rows;
    if (rows == null) return null;
    for (final r in rows) {
      if (idOf(r) == id) return r;
    }
    return null;
  }

  List<T> where(bool Function(T row) test) =>
      (_rows ?? <T>[]).where(test).toList();

  Future<void> upsert(T row) async {
    await load();
    final rows = _rows!;
    final id = idOf(row);
    final i = rows.indexWhere((r) => idOf(r) == id);
    if (i >= 0) {
      rows[i] = row;
    } else {
      rows.add(row);
    }
    await _flush();
  }

  Future<void> upsertAll(Iterable<T> newRows) async {
    await load();
    final rows = _rows!;
    for (final row in newRows) {
      final id = idOf(row);
      final i = rows.indexWhere((r) => idOf(r) == id);
      if (i >= 0) {
        rows[i] = row;
      } else {
        rows.add(row);
      }
    }
    await _flush();
  }

  Future<void> replaceAll(Iterable<T> newRows) async {
    _rows = newRows.toList();
    await _flush();
  }

  Future<bool> deleteById(String id) async {
    await load();
    final rows = _rows!;
    final i = rows.indexWhere((r) => idOf(r) == id);
    if (i < 0) return false;
    rows.removeAt(i);
    await _flush();
    return true;
  }

  Future<void> removeWhere(bool Function(T row) test) async {
    await load();
    _rows!.removeWhere(test);
    await _flush();
  }

  Future<void> clear() async {
    _rows = <T>[];
    await kv.remove(storageKey(name));
  }
}
