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
}
