/// 朗读短句片段：段落文本中的一两句话，携带在**原段落文本**中的字符区间，
/// 供阅读页按句高亮（区间口径与 JS `textOf(node)` 的归一化结果一致）。
class TtsTextSegment {
  const TtsTextSegment(this.text, this.start, this.end);

  /// 实际送给引擎合成的文本（已去首尾空白）。
  final String text;

  /// 在段落文本中的起始字符下标（含）。
  final int start;

  /// 在段落文本中的结束字符下标（不含）。
  final int end;
}

/// 把一整段正文切成「一两句话」的朗读片段。
///
/// 目的：首次合成请求不再携带整段长文（Edge TTS 首包明显更快），
/// 朗读高亮也只覆盖一两句。段落下标、断点与进度仍按原段落计算，
/// 因此 [TtsTextSegment.start]/[end] 只用于高亮，不改变朗读坐标。
class TtsTextSplitter {
  const TtsTextSplitter({
    this.maxChars = defaultMaxChars,
    this.maxSentences = 2,
  });

  /// 单个片段的最大字符数：约一两句话，首请求体量可控。
  static const int defaultMaxChars = 80;

  final int maxChars;
  final int maxSentences;

  /// 句末标点（含常见收尾引号/括号），英文句点只在后接空白或结尾时生效，
  /// 避免把小数点、缩写切开。
  static final RegExp _sentenceEnd = RegExp(
    r'(?:[。！？!?；;…]+|\.+(?=\s|$))[”’"）)\]】』」\s]*',
  );

  static final RegExp _softBreak = RegExp(r'[，,、：:；; ]');

  List<TtsTextSegment> split(String paragraph) {
    final text = paragraph.trim();
    if (text.isEmpty) return const [];

    final units = _sentenceSpans(text);
    if (units.isEmpty) return const [];

    final segments = <TtsTextSegment>[];
    var groupStart = -1;
    var groupEnd = -1;
    var unitCount = 0;

    void emit() {
      if (groupStart < 0) return;
      final raw = text.substring(groupStart, groupEnd);
      final trimmed = raw.trim();
      if (trimmed.isNotEmpty) {
        final offset = raw.indexOf(trimmed);
        segments.add(
          TtsTextSegment(
            trimmed,
            groupStart + offset,
            groupStart + offset + trimmed.length,
          ),
        );
      }
      groupStart = -1;
      groupEnd = -1;
      unitCount = 0;
    }

    for (final unit in units) {
      final length = (groupStart < 0 ? 0 : groupEnd - groupStart) +
          (unit.end - unit.start);
      // 合并到两句或接近上限就先收一段，保证每个请求都足够短。
      if (groupStart >= 0 && (unitCount >= maxSentences || length > maxChars)) {
        emit();
      }
      if (groupStart < 0) groupStart = unit.start;
      groupEnd = unit.end;
      unitCount++;
    }
    emit();
    return segments;
  }

  List<_Span> _sentenceSpans(String text) {
    final spans = <_Span>[];
    var cursor = 0;
    for (final match in _sentenceEnd.allMatches(text)) {
      if (match.end > cursor) {
        spans.addAll(_chunks(text, cursor, match.end));
      }
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.addAll(_chunks(text, cursor, text.length));
    }
    return spans;
  }

  /// 无标点 / 超长句子按长度硬切，优先在逗号、顿号、空格处断开。
  List<_Span> _chunks(String text, int start, int end) {
    final spans = <_Span>[];
    var cursor = start;
    while (end - cursor > maxChars) {
      var cut = cursor + maxChars;
      final half = cursor + (maxChars ~/ 2);
      for (var i = cut - 1; i >= half; i--) {
        if (_softBreak.hasMatch(text[i])) {
          cut = i + 1;
          break;
        }
      }
      spans.add(_Span(cursor, cut));
      cursor = cut;
    }
    if (cursor < end) spans.add(_Span(cursor, end));
    return spans;
  }
}

class _Span {
  const _Span(this.start, this.end);

  final int start;
  final int end;
}
