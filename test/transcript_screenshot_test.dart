import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kele_audio/app/theme/app_palette.dart';
import 'package:kele_audio/app/theme/app_theme.dart';
import 'package:kele_audio/app/theme/app_tokens.dart';
import 'package:kele_audio/core/api/subtitle_source.dart';
import 'package:kele_audio/features/player/transcript_body.dart';

const _fontFamily = 'KeleShotFont';

/// 文稿跟随高亮的**交付截图**（输出到 `docs/shortscreen`，AGENT.md 约定）。
///
/// widget 测试拿不到系统字体（默认 Ahem 方块），这里把 Windows 系统字体的
/// 字节注册进渲染树，让截图文案可读；字幕/播放位置均为假数据，
/// 不触网、不依赖 PlayerService。
Future<void> _loadTestFont() async {
  const candidates = [
    r'C:\Windows\Fonts\simhei.ttf', // 黑体（单文件 TTF，最常见）
    r'C:\Windows\Fonts\Deng.ttf', // 等线
    r'C:\Windows\Fonts\msyh.ttf',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final bytes = await file.readAsBytes();
    final loader = FontLoader(_fontFamily)
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
    return;
  }
  fail('未找到系统中文 TTF 字体，无法生成可读截图');
}

/// 原创示例文稿（14 句，长短参差以展示换行居中效果）。
List<SubtitleCue> _demoCues() {
  const lines = <String>[
    '清晨的雾还没有散，山道旁的芦苇沾满了细小的水珠。',
    '少年背着一只旧布包，沿着青石台阶一步一步往上走。',
    '风从峡谷深处吹来，带着松针和溪水混合的气味。',
    '他在半山腰的小亭子里歇脚，忽然听见身后传来一串清脆的铃声。',
    '翻过最后一级石阶，眼前豁然开朗：一片云海铺在天边。',
    '云海的尽头立着一座孤零零的邮亭，绿色的木牌已经褪了色。',
    '邮亭的主人是位银白头发的老奶奶，正低头修补一封湿透的信。',
    '听说这邮亭只为山那头的人们送信，一天只有一趟，雾散才出发。',
    '少年不敢打扰，只在远处静静地等，看雾气一寸寸退向山脚。',
    '老奶奶抬起头，朝他招了招手，示意亭子里还有一个空座。',
    '我刚要把最深的那封信送到山那边去，她轻声说。',
    '如果你愿意陪我走一段雾里的路，我就把故事讲给你听。',
    '少年点点头，把布包抱得更紧了些，铃声又在雾中轻轻响起。',
    '他们一前一后走进云里，脚步声与铃声渐渐混在一起，听不分明了。',
  ];
  return List.generate(
    lines.length,
    (i) => SubtitleCue(
      fromSec: i * 5.4,
      toSec: i * 5.4 + 4.9,
      content: lines[i],
    ),
  );
}

/// 亮/暗两套主题各渲染一帧，Cell 中心对齐在第 7 句（index 6）。
Future<void> _capture({
  required AppThemePreset preset,
  required WidgetTester tester,
  required String outPath,
}) async {
  final theme = AppTheme.of(preset);
  final shotTheme = theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamily: _fontFamily),
  );
  final tokens = AppTokens.ofPalette(preset.palette);
  final position = ValueNotifier<Duration>(
    const Duration(milliseconds: 34200),
  ); // 第 7 句中段
  final boundaryKey = GlobalKey();

  await tester.pumpWidget(
    RepaintBoundary(
      key: boundaryKey,
      child: MaterialApp(
        theme: shotTheme,
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SafeArea(
            // 对齐播放页布局：水平 spaceLg，上区「固定标题 + 文稿正文」
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: tokens.spaceLg),
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.only(
                      top: tokens.spaceXs,
                      bottom: tokens.spaceSm,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '山谷来信 · 全一卷',
                          style: tokens.titleStyle,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '第 7 章 · 雾中铃声',
                          style: tokens.captionStyle,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: TranscriptBody(
                      cues: _demoCues(),
                      positionTick: position,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  // 首帧定位（估高跳位 + 下一帧精确校正）与动画全部落定
  await tester.pumpAndSettle(const Duration(milliseconds: 100));

  await tester.runAsync(() async {
    final element = boundaryKey.currentContext!;
    final boundary =
        element.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 3.0);
    try {
      final data =
          await image.toByteData(format: ui.ImageByteFormat.png);
      await File(outPath).writeAsBytes(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });

  expect(File(outPath).existsSync(), isTrue, reason: '必须写出 $outPath');
}

void main() {
  testWidgets('文稿跟随高亮截图（亮色 / 暗色主题）', (tester) async {
    final view = tester.view;
    view.devicePixelRatio = 3.0;
    view.physicalSize = const Size(1170, 2280);
    addTearDown(view.reset);

    // 系统字体注册需在渲染前的 runAsync 里完成
    await tester.runAsync(_loadTestFont);

    await _capture(
      preset: AppThemePreset.warmPaper,
      tester: tester,
      outPath: 'docs/shortscreen/transcript-follow-warm-paper.png',
    );
    await _capture(
      preset: AppThemePreset.darkGold,
      tester: tester,
      outPath: 'docs/shortscreen/transcript-follow-dark-gold.png',
    );
  });
}
