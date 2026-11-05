import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../api/key_value_store.dart';

/// 阅读进度细粒度真源（`reader_progress_{id}`）。
///
/// `ReaderBook` 上的章节/百分比是书架列表用的冗余字段；
/// 精确续读依赖这里的 CFI（章内位置），冷启动时优先按 CFI 复原。
class ReaderProgress {
  const ReaderProgress({
    this.cfi = '',
    this.chapterIndex = 0,
    this.fraction = 0,
    this.savedAt,
  });

  final String cfi;
  final int chapterIndex;
  final double fraction;
  final DateTime? savedAt;

  Map<String, dynamic> toJson() => {
    'cfi': cfi,
    'chapterIndex': chapterIndex,
    'fraction': fraction,
    'savedAt': savedAt?.toIso8601String(),
  };

  factory ReaderProgress.fromJson(Map<String, dynamic> json) {
    return ReaderProgress(
      cfi: json['cfi']?.toString() ?? '',
      chapterIndex: (json['chapterIndex'] as num?)?.toInt() ?? 0,
      fraction: (json['fraction'] as num?)?.toDouble() ?? 0,
      savedAt: DateTime.tryParse(json['savedAt']?.toString() ?? ''),
    );
  }
}

class ReaderProgressStore {
  ReaderProgressStore(this._kv);

  final KeyValueStore _kv;

  static String keyFor(String bookId) => 'reader_progress_$bookId';

  ReaderProgress? read(String bookId) {
    final raw = _kv.getString(keyFor(bookId));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return ReaderProgress.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (e) {
      debugPrint('[reader] 读取阅读进度失败：$e');
    }
    return null;
  }

  Future<void> save(String bookId, ReaderProgress progress) async {
    await _kv.setString(
      keyFor(bookId),
      jsonEncode({
        ...progress.toJson(),
        'savedAt': (progress.savedAt ?? DateTime.now()).toIso8601String(),
      }),
    );
  }

  /// 删除书籍时清理进度。
  Future<void> remove(String bookId) async {
    await _kv.remove(keyFor(bookId));
  }
}
