import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kele_audio/core/api/key_value_store.dart';
import 'package:kele_audio/core/services/reader/reader_bridge.dart';
import 'package:kele_audio/core/services/reader/reader_progress_store.dart';
import 'package:kele_audio/core/services/reader/reader_typography.dart';

void main() {
  group('桥消息解析', () {
    test('合法消息解出 name 与 payload', () {
      final message = ReaderBridgeMessage.parse({
        'name': 'onRelocated',
        'payload': {'index': 2, 'fraction': 0.35, 'cfi': 'epubcfi(/6/8!/4/2)'},
      });
      expect(message, isNotNull);
      expect(message!.name, 'onRelocated');
      expect(message.payload['index'], 2);
      expect(message.payload['fraction'], 0.35);
    });

    test('结构非法时返回 null，不抛异常', () {
      expect(ReaderBridgeMessage.parse(null), isNull);
      expect(ReaderBridgeMessage.parse('oops'), isNull);
      expect(ReaderBridgeMessage.parse({'payload': {}}), isNull);
      expect(ReaderBridgeMessage.parse({'name': ''}), isNull);
    });

    test('payload 缺失时退化为空 map', () {
      final message = ReaderBridgeMessage.parse({'name': 'onReady'});
      expect(message, isNotNull);
      expect(message!.payload, isEmpty);
    });
  });

  group('样式载荷', () {
    test('颜色转 #RRGGBB，模式转 foliate 取值', () {
      final payload = ReaderStylePayload(
        typography: const ReaderTypography(fontSize: 17, flow: ReaderFlow.scrolled),
        background: const Color(0xFFF7F1E7),
        foreground: const Color(0xFF2B2620),
        muted: const Color(0xFF8A8070),
        accent: const Color(0xFFB4552F),
        hairline: const Color(0xFFE0D6C6),
        isDark: false,
      );
      final json = payload.toJson();
      expect(json['mode'], 'scrolled');
      expect((json['colors'] as Map)['bg'], '#f7f1e7');
      expect((json['colors'] as Map)['fg'], '#2b2620');
      expect(json['fontSize'], 17);
      expect(json['weight'], 400);
    });
  });

  group('排版设置', () {
    test('JSON 往返保持字段', () {
      const typography = ReaderTypography(
        fontSize: 22,
        lineHeight: 2.0,
        margin: 30,
        weight: 600,
        flow: ReaderFlow.scrolled,
      );
      final restored = ReaderTypography.fromJson(typography.toJson());
      expect(restored.fontSize, 22);
      expect(restored.lineHeight, 2.0);
      expect(restored.margin, 30);
      expect(restored.weight, 600);
      expect(restored.flow, ReaderFlow.scrolled);
    });

    test('越界值被钳制，非法字重回退 400', () {
      final restored = ReaderTypography.fromJson({
        'fontSize': 200,
        'lineHeight': 0.1,
        'margin': -5,
        'weight': 700,
      });
      expect(restored.fontSize, ReaderTypography.maxFontSize);
      expect(restored.lineHeight, ReaderTypography.minLineHeight);
      expect(restored.margin, ReaderTypography.minMargin);
      expect(restored.weight, 400);
    });

    test('存储持久化并可重置', () async {
      final kv = MemoryKeyValueStore();
      final store = ReaderTypographyStore(kv);
      await store.load();
      expect(store.value, ReaderTypography.defaults);
      await store.update(const ReaderTypography(fontSize: 20, weight: 500));
      expect(kv.getString(ReaderTypographyStore.storageKey), contains('20'));

      final reloaded = ReaderTypographyStore(kv);
      await reloaded.load();
      expect(reloaded.value.fontSize, 20);
      expect(reloaded.value.weight, 500);

      await reloaded.reset();
      expect(reloaded.value, ReaderTypography.defaults);
    });
  });

  group('阅读进度', () {
    test('保存后可精确恢复，删除后清空', () async {
      final kv = MemoryKeyValueStore();
      final store = ReaderProgressStore(kv);
      await store.save(
        'book-1',
        const ReaderProgress(
          cfi: 'epubcfi(/6/10!/4/2/2)',
          chapterIndex: 4,
          fraction: 0.42,
        ),
      );

      final restored = store.read('book-1');
      expect(restored, isNotNull);
      expect(restored!.cfi, 'epubcfi(/6/10!/4/2/2)');
      expect(restored.chapterIndex, 4);
      expect(restored.fraction, 0.42);
      expect(restored.savedAt, isNotNull);

      await store.remove('book-1');
      expect(store.read('book-1'), isNull);
    });

    test('损坏 JSON 返回 null 不崩', () {
      final kv = MemoryKeyValueStore();
      kv.setString(ReaderProgressStore.keyFor('broken'), '{oops');
      expect(ReaderProgressStore(kv).read('broken'), isNull);
    });
  });
}
