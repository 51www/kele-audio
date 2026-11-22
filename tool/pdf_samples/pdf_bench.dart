// PDF 样本抽取基准（M10.0 证据采集）。
//
// 说明：本工具是纯 Dart CLI，直接调用 pdfrx_engine（pdfrx 的底层引擎，
// 不依赖 Flutter），因此可输出 ProcessInfo 峰值 RSS 作为 Android 侧
// 内存的近似参考。运行前需允许 native assets 构建（Windows 需开启
// 开发者模式，由 pdfium_dart 的 build hook 拉取 prebuilt pdfium）。
//
// 用法：dart run tool/pdf_samples/pdf_bench.dart
//
// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:pdfrx_engine/pdfrx_engine.dart';

bool _isCjk(int code) =>
    (code >= 0x4e00 && code <= 0x9fff) ||
    (code >= 0x3400 && code <= 0x4dbf) ||
    (code >= 0x3000 && code <= 0x303f) ||
    (code >= 0xff00 && code <= 0xffef);

bool _isSuspicious(int code) {
  if (code == 0xfffd) return true; // 替换字符
  if (code < 0x20 && code != 0x0a && code != 0x0d && code != 0x09) return true;
  if (code >= 0xe000 && code <= 0xf8ff) return true; // 私用区
  return false;
}

Future<void> main(List<String> args) async {
  final dir = Directory(args.isNotEmpty ? args.first : 'docs/pdf-samples');
  if (!dir.existsSync()) {
    stderr.writeln('目录不存在：${dir.path}');
    exitCode = 2;
    return;
  }

  await pdfrxInitialize();

  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.pdf'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in files) {
    final name = file.uri.pathSegments.last;
    final sizeKb = file.lengthSync() / 1024;
    stdout.writeln('\n=== $name (${sizeKb.toStringAsFixed(1)} KB) ===');

    final rssBefore = ProcessInfo.currentRss;
    final openWatch = Stopwatch()..start();
    final doc = await PdfDocument.openFile(file.path);
    openWatch.stop();

    final pageCount = doc.pages.length;
    stdout.writeln(
      'pages=$pageCount  open=${openWatch.elapsedMilliseconds} ms  '
      'rssBefore=${(rssBefore / 1024 / 1024).toStringAsFixed(1)} MB',
    );

    final extractWatch = Stopwatch()..start();
    var totalChars = 0;
    var suspicious = 0;
    final pageTexts = <String>[];
    for (final page in doc.pages) {
      final text = await page.loadStructuredText(ensureLoaded: false);
      pageTexts.add(text.fullText);
      totalChars += text.fullText.length;
      for (final code in text.fullText.runes) {
        if (_isSuspicious(code)) suspicious++;
      }
    }
    extractWatch.stop();
    final rssPeak = ProcessInfo.currentRss;

    final cjkChars = pageTexts.fold<int>(
      0,
      (sum, t) => sum + t.runes.where(_isCjk).length,
    );
    final nonEmptyPages = pageTexts.where((t) => t.trim().isNotEmpty).length;
    final avgChars = pageCount == 0 ? 0 : totalChars / pageCount;
    final garbleRate = totalChars == 0 ? 0 : suspicious / totalChars;
    final cjkRate = totalChars == 0 ? 0 : cjkChars / totalChars;

    stdout.writeln(
      'extract=${extractWatch.elapsedMilliseconds} ms  '
      'chars=$totalChars  avgChars/page=${avgChars.toStringAsFixed(1)}  '
      'nonEmptyPages=$nonEmptyPages  '
      'cjkRate=${(cjkRate * 100).toStringAsFixed(1)}%  '
      'garbleRate=${(garbleRate * 100).toStringAsFixed(2)}%  '
      'rssAfter=${(rssPeak / 1024 / 1024).toStringAsFixed(1)} MB',
    );

    // 顺序抽读：双栏样本重点看跨栏是否串行。
    for (final i in [0, 1, 2]) {
      if (i >= pageTexts.length || pageTexts[i].trim().isEmpty) continue;
      final sample = pageTexts[i].replaceAll('\n', ' / ').trim();
      final clipped = sample.length > 220 ? '${sample.substring(0, 220)}…' : sample;
      stdout.writeln('  p${i + 1}: $clipped');
    }

    await doc.dispose();
    // 给 GC/原生释放一点时间再测下一页的起点内存。
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}
