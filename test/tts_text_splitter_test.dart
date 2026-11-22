import 'package:flutter_test/flutter_test.dart';

import 'package:kele_audio/core/services/tts/tts_text_splitter.dart';

void main() {
  const splitter = TtsTextSplitter();

  test('中文多句按一两句切开，字符区间与文本一致', () {
    const text = '桥头下着雨。风很大，他走进巷子。远处传来钟声。天亮了。';
    final segments = splitter.split(text);
    expect(segments.length, 2);
    expect(segments.first.text, '桥头下着雨。风很大，他走进巷子。');
    expect(segments.last.text, '远处传来钟声。天亮了。');
    for (final segment in segments) {
      expect(text.substring(segment.start, segment.end), segment.text);
    }
  });

  test('短段落保持单个片段', () {
    const text = '第一段';
    final segments = splitter.split(text);
    expect(segments.length, 1);
    expect(segments.single.text, text);
    expect(segments.single.start, 0);
    expect(segments.single.end, text.length);
  });

  test('无标点长文本按上限硬切，不丢字', () {
    final text = '风' * 200;
    final segments = splitter.split(text);
    expect(segments.length, greaterThan(1));
    for (final segment in segments) {
      expect(
        segment.text.length,
        lessThanOrEqualTo(TtsTextSplitter.defaultMaxChars),
      );
      expect(text.substring(segment.start, segment.end), segment.text);
    }
    expect(segments.map((s) => s.text).join(), text);
  });

  test('英文句点后接空白才切句，小数点不切', () {
    const text = 'He stopped. Then he left. The value is 3.14 units.';
    final segments = splitter.split(text);
    expect(segments.map((s) => s.text).join(' '), contains('3.14'));
    for (final segment in segments) {
      expect(text.substring(segment.start, segment.end), segment.text);
    }
  });

  test('长段落首片段不超过上限，首请求体量受控', () {
    final text = '第一段内容很长，' * 30 + '。';
    final segments = splitter.split(text);
    expect(segments.length, greaterThan(1));
    expect(
      segments.first.text.length,
      lessThanOrEqualTo(TtsTextSplitter.defaultMaxChars),
    );
    for (final segment in segments) {
      expect(text.substring(segment.start, segment.end), segment.text);
    }
  });

  test('空段落返回空列表', () {
    expect(splitter.split(''), isEmpty);
    expect(splitter.split('   '), isEmpty);
  });

  test('纯数字/纯标点段落（页码）不产生朗读片段', () {
    for (final text in ['5', '12', '2024 / 2025', '- 3 -', '…']) {
      expect(splitter.split(text), isEmpty, reason: text);
    }
  });

  test('含文字的段落即使夹杂数字仍正常朗读', () {
    final segments = splitter.split('第12章开始了。');
    expect(segments, hasLength(1));
    expect(segments.single.text, '第12章开始了。');
  });

  test('半角标点归一且字符长度不变', () {
    const text = '你好,世界;今天呢?真的吗!';
    final normalized = TtsTextSplitter.normalizePunctuation(text);
    expect(normalized.length, text.length);
    expect(normalized, '你好，世界；今天呢？真的吗！');

    final segments = splitter.split(text);
    expect(segments, hasLength(1));
    expect(segments.single.text, normalized);
    expect(segments.single.start, 0);
    expect(segments.single.end, text.length);
    expect(
      normalized.substring(segments.single.start, segments.single.end),
      segments.single.text,
    );
  });

  test('相邻短句合并成单个片段，不丢字', () {
    const text = '他来了。雨停了。天空很蓝。';
    final segments = splitter.split(text);
    expect(segments, hasLength(1));
    expect(segments.single.text, text);
    expect(segments.single.start, 0);
    expect(segments.single.end, text.length);
  });

  test('perSentence：标点即句界，短句不合并，区间与原文一致', () {
    const text = '桥头下着雨。风很大，他走进巷子。远处传来钟声。';
    const perSentence = TtsTextSplitter.perSentence();
    final segments = perSentence.split(text);
    expect(
      segments.map((s) => s.text).toList(),
      ['桥头下着雨。', '风很大，他走进巷子。', '远处传来钟声。'],
    );
    for (final segment in segments) {
      expect(text.substring(segment.start, segment.end), segment.text);
    }
  });
}
