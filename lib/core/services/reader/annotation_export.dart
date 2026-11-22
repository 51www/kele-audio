import 'dart:convert';
import 'dart:typed_data';

import '../../domain/reader_annotation.dart';

/// 划线导出：只输出划线文本，一行一条。
class AnnotationExportService {
  AnnotationExportService._();

  static String suggestedFileName(DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    return 'kele-annotations-'
        '${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}.txt';
  }

  static Uint8List buildText(List<ReaderAnnotation> items) {
    final lines = items
        .map((item) => item.text.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((text) => text.isNotEmpty);
    return Uint8List.fromList(utf8.encode(lines.join('\n')));
  }
}
