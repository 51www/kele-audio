import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../api/key_value_store.dart';

/// 阅读/听书方式。
enum ReaderActivityMode { reading, listening }

extension ReaderActivityModeX on ReaderActivityMode {
  String get storageValue => name;
  String get label => switch (this) {
    ReaderActivityMode.reading => '阅读',
    ReaderActivityMode.listening => '听书',
  };

  static ReaderActivityMode fromStorage(String? value) =>
      value == ReaderActivityMode.listening.storageValue
          ? ReaderActivityMode.listening
          : ReaderActivityMode.reading;
}

/// 历史页「阅读」分组的一条记录。
class ReaderHistoryEntry {
  const ReaderHistoryEntry({
    required this.bookId,
    required this.bookTitle,
    required this.chapterTitle,
    required this.mode,
    required this.at,
  });

  final String bookId;
  final String bookTitle;
  final String chapterTitle;
  final ReaderActivityMode mode;
  final DateTime at;

  Map<String, dynamic> toJson() => {
    'bookId': bookId,
    'bookTitle': bookTitle,
    'chapterTitle': chapterTitle,
    'mode': mode.storageValue,
    'at': at.toIso8601String(),
  };

  factory ReaderHistoryEntry.fromJson(Map<String, dynamic> json) {
    return ReaderHistoryEntry(
      bookId: json['bookId']?.toString() ?? '',
      bookTitle: json['bookTitle']?.toString() ?? '',
      chapterTitle: json['chapterTitle']?.toString() ?? '',
      mode: ReaderActivityModeX.fromStorage(json['mode']?.toString()),
      at: DateTime.tryParse(json['at']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}

/// 统计页「阅读时长」的埋点：按 日期 + 书籍 + 方式 聚合。
class ReaderLogEntry {
  const ReaderLogEntry({
    required this.date,
    required this.bookId,
    required this.durationSec,
    required this.mode,
  });

  /// yyyy-MM-dd。
  final String date;
  final String bookId;
  final int durationSec;
  final ReaderActivityMode mode;

  Map<String, dynamic> toJson() => {
    'date': date,
    'bookId': bookId,
    'durationSec': durationSec,
    'mode': mode.storageValue,
  };

  factory ReaderLogEntry.fromJson(Map<String, dynamic> json) {
    return ReaderLogEntry(
      date: json['date']?.toString() ?? '',
      bookId: json['bookId']?.toString() ?? '',
      durationSec: (json['durationSec'] as num?)?.toInt() ?? 0,
      mode: ReaderActivityModeX.fromStorage(json['mode']?.toString()),
    );
  }
}

/// 阅读历史与时长埋点存储（M9.1 建立数据域，M9.2/M9.3 开始写入）。
///
/// 独立于 `play_history` / `play_log`：本地书活动只在阅读相关页面消费，
/// 不改动现有收听历史与收听统计。
class ReaderActivityStore extends ChangeNotifier {
  ReaderActivityStore(this._kv);

  static const historyKey = 'reader_history';
  static const logKey = 'reader_log';

  /// 历史最多保留条数，避免 shared_preferences 无限膨胀。
  static const int maxHistory = 300;

  final KeyValueStore _kv;
  final List<ReaderHistoryEntry> _history = [];
  final List<ReaderLogEntry> _log = [];

  bool _loaded = false;
  bool get loaded => _loaded;

  List<ReaderHistoryEntry> get history => List.unmodifiable(_history);
  List<ReaderLogEntry> get log => List.unmodifiable(_log);

  Future<void> load() async {
    _history
      ..clear()
      ..addAll(_decodeHistory(_kv.getString(historyKey)));
    _log
      ..clear()
      ..addAll(_decodeLog(_kv.getString(logKey)));
    _loaded = true;
    notifyListeners();
  }

  List<ReaderHistoryEntry> _decodeHistory(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is Map)
            ReaderHistoryEntry.fromJson(Map<String, dynamic>.from(item)),
      ];
    } catch (e) {
      debugPrint('[reader] 读取 reader_history 失败：$e');
      return const [];
    }
  }

  List<ReaderLogEntry> _decodeLog(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is Map)
            ReaderLogEntry.fromJson(Map<String, dynamic>.from(item)),
      ];
    } catch (e) {
      debugPrint('[reader] 读取 reader_log 失败：$e');
      return const [];
    }
  }

  Future<void> recordHistory(ReaderHistoryEntry entry) async {
    _history.insert(0, entry);
    if (_history.length > maxHistory) {
      _history.removeRange(maxHistory, _history.length);
    }
    notifyListeners();
    await _kv.setString(
      historyKey,
      jsonEncode([for (final item in _history) item.toJson()]),
    );
  }

  /// 追加时长；同一天同一本书同一方式合并成一条。
  Future<void> logDuration({
    required String bookId,
    required int durationSec,
    required ReaderActivityMode mode,
    DateTime? at,
  }) async {
    if (durationSec <= 0) return;
    final date = _dateKey(at ?? DateTime.now());
    final index = _log.indexWhere(
      (e) => e.date == date && e.bookId == bookId && e.mode == mode,
    );
    if (index >= 0) {
      final old = _log[index];
      _log[index] = ReaderLogEntry(
        date: date,
        bookId: bookId,
        durationSec: old.durationSec + durationSec,
        mode: mode,
      );
    } else {
      _log.add(
        ReaderLogEntry(
          date: date,
          bookId: bookId,
          durationSec: durationSec,
          mode: mode,
        ),
      );
    }
    notifyListeners();
    await _kv.setString(
      logKey,
      jsonEncode([for (final item in _log) item.toJson()]),
    );
  }

  /// 本周（周一至今）阅读/听书总时长（秒）。
  int secondsSince(DateTime start) {
    final startKey = _dateKey(start);
    var total = 0;
    for (final entry in _log) {
      if (entry.date.compareTo(startKey) >= 0) total += entry.durationSec;
    }
    return total;
  }

  int get totalSeconds =>
      _log.fold(0, (sum, entry) => sum + entry.durationSec);

  /// 按日期聚合，供统计页趋势图。
  Map<String, int> secondsByDate() {
    final result = <String, int>{};
    for (final entry in _log) {
      result[entry.date] = (result[entry.date] ?? 0) + entry.durationSec;
    }
    return result;
  }

  /// 删除书籍时清理其历史与日志。
  Future<void> removeBook(String bookId) async {
    _history.removeWhere((e) => e.bookId == bookId);
    _log.removeWhere((e) => e.bookId == bookId);
    notifyListeners();
    await _kv.setString(
      historyKey,
      jsonEncode([for (final item in _history) item.toJson()]),
    );
    await _kv.setString(
      logKey,
      jsonEncode([for (final item in _log) item.toJson()]),
    );
  }

  static String _dateKey(DateTime time) {
    final month = time.month.toString().padLeft(2, '0');
    final day = time.day.toString().padLeft(2, '0');
    return '${time.year}-$month-$day';
  }
}
