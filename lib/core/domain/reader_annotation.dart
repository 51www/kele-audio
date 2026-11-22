import 'dart:convert';

/// 划线颜色（同时作为 WebView 覆盖层绘制色键）。
enum ReaderAnnotationColor {
  yellow,
  green,
  blue,
  pink;

  String get jsValue => name;

  String get label => switch (this) {
        yellow => '黄色',
        green => '绿色',
        blue => '蓝色',
        pink => '粉色',
      };

  static ReaderAnnotationColor from(String? value) =>
      ReaderAnnotationColor.values.firstWhere(
        (c) => c.jsValue == value,
        orElse: () => ReaderAnnotationColor.yellow,
      );
}

/// 一条用户划线（原文定位 + 快照文本）。
///
/// `cfi` 为 foliate-js 生成的 EPUB 范围 CFI；`text` 是选中文本快照，
/// 既用于标注列表展示，也用于 CFI 失效后的文本兜底定位。
/// `bookTitle` / `chapterTitle` 是入库时快照，保证书籍被软删或目录变化时
/// 全局标注列表仍可展示可读上下文。
class ReaderAnnotation {
  const ReaderAnnotation({
    required this.id,
    required this.bookId,
    required this.bookTitle,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.cfi,
    required this.text,
    required this.color,
    required this.createdAt,
    required this.updatedAt,
    this.note,
    this.fraction,
  });

  final String id;
  final String bookId;
  final String bookTitle;
  final int chapterIndex;
  final String chapterTitle;
  final String cfi;
  final String text;
  final ReaderAnnotationColor color;
  final String? note;
  final double? fraction;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get hasNote => note != null && note!.trim().isNotEmpty;

  ReaderAnnotation copyWith({
    String? note,
    ReaderAnnotationColor? color,
    DateTime? updatedAt,
  }) {
    return ReaderAnnotation(
      id: id,
      bookId: bookId,
      bookTitle: bookTitle,
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle,
      cfi: cfi,
      text: text,
      color: color ?? this.color,
      note: note ?? this.note,
      fraction: fraction,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'bookId': bookId,
        'bookTitle': bookTitle,
        'chapterIndex': chapterIndex,
        'chapterTitle': chapterTitle,
        'cfi': cfi,
        'text': text,
        'color': color.jsValue,
        'note': note,
        'fraction': fraction,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory ReaderAnnotation.fromJson(Map<String, dynamic> json) {
    return ReaderAnnotation(
      id: json['id']?.toString() ?? '',
      bookId: json['bookId']?.toString() ?? '',
      bookTitle: json['bookTitle']?.toString() ?? '',
      chapterIndex: (json['chapterIndex'] as num?)?.toInt() ?? 0,
      chapterTitle: json['chapterTitle']?.toString() ?? '',
      cfi: json['cfi']?.toString() ?? '',
      text: json['text']?.toString() ?? '',
      color: ReaderAnnotationColor.from(json['color']?.toString()),
      note: json['note']?.toString(),
      fraction: (json['fraction'] as num?)?.toDouble(),
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt:
          DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  static List<ReaderAnnotation> decodeList(Object? raw) {
    if (raw is! List) return const [];
    final result = <ReaderAnnotation>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final annotation = ReaderAnnotation.fromJson(Map<String, dynamic>.from(item));
      if (annotation.id.isNotEmpty && annotation.bookId.isNotEmpty) {
        result.add(annotation);
      }
    }
    return result;
  }

  static String encodeList(List<ReaderAnnotation> items) =>
      jsonEncode(items.map((e) => e.toJson()).toList());
}
