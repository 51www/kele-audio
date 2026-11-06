import 'package:flutter_test/flutter_test.dart';
import 'package:kele_audio/core/services/tts/mimo_text_splitter.dart';

void main() {
  const splitter = MimoTextSplitter();

  String stripSpaces(String value) =>
      value.replaceAll(RegExp(r'\s+'), '');

  test('每片不超过上限且内容不丢', () {
    final text = ('这是第一句话，用来测试切片。' * 40);
    final chunks = splitter.split(text);
    expect(chunks, isNotEmpty);
    for (final chunk in chunks) {
      expect(chunk.length, lessThanOrEqualTo(MimoTextSplitter.defaultMaxChars));
      expect(chunk.trim(), chunk);
    }
    expect(stripSpaces(chunks.join()), stripSpaces(text));
  });

  test('优先在句末标点处断开', () {
    final sentence = '${'春' * 38}。';
    final chunks = splitter.split(sentence * 4);
    // 38*4 字 → 每片可容纳 3 句（117 字），共 2 片。
    expect(chunks.length, 2);
    expect(chunks.first.endsWith('。'), isTrue);
    expect(chunks.last.endsWith('。'), isTrue);
  });

  test('超长单句降级到逗号，不在引号内断开', () {
    final opener = '“' * 0;
    final text = '$opener${'甲' * 60}，${'乙' * 60}，${'丙' * 60}。';
    final chunks = splitter.split(text);
    for (final chunk in chunks) {
      expect(chunk.length, lessThanOrEqualTo(150));
    }
    expect(stripSpaces(chunks.join()), stripSpaces(text));
    // 逗号保留在前一片，不出现以逗号开头的片。
    expect(chunks.any((c) => c.startsWith('，')), isFalse);
  });

  test('硬切不把数字拆到两片', () {
    final digits = List.generate(400, (i) => '${i % 10}').join();
    final chunks = splitter.split(digits);
    expect(chunks.length, greaterThan(1));
    expect(chunks.join(), digits);
  });

  test('splitInTwo 返回更短的两片', () {
    final source = '${'前' * 70}，${'后' * 70}。';
    final parts = splitter.splitInTwo(source);
    expect(parts.length, 2);
    expect(parts.first.length, lessThan(source.length));
    expect(parts.last.trim().endsWith('。'), isTrue);
    expect(stripSpaces(parts.join()), stripSpaces(source));
  });

  test('空文本与纯空白不产生片', () {
    expect(splitter.split(''), isEmpty);
    expect(splitter.split(' \n\t '), isEmpty);
  });
}
