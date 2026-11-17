/// 朗读短句片段：段落文本中的一两句话，携带在**原段落文本**中的字符区间，
/// 供阅读页按句高亮（区间口径与 JS `textOf(node)` 的归一化结果一致）。
class TtsTextSegment {
  const TtsTextSegment(this.text, this.start, this.end);

  /// 实际送给引擎合成的文本（已去首尾空白，半角标点已归一）。
  final String text;

  /// 在段落文本中的起始字符下标（含）。
  final int start;

  /// 在段落文本中的结束字符下标（不含）。
  final int end;
}

/// 把一整段正文切成「一两句话」的朗读片段（短句合并时最多三句）。
///
/// 目的：首次合成请求不再携带整段长文（Edge TTS 首包明显更快），
/// 朗读高亮也只覆盖当前短句。段落下标、断点与进度仍按原段落计算，
/// 因此 [TtsTextSegment.start]/[end] 只用于高亮，不改变朗读坐标。
class TtsTextSplitter {
  const TtsTextSplitter({
    this.maxChars = defaultMaxChars,
    this.minChars = defaultMinChars,
    this.maxSentences = 2,
  });

  /// 单个片段的最大字符数：约一两句话，首请求体量可控。
  static const int defaultMaxChars = 80;

  /// 小于该长度的片段会尝试与相邻短句合并，减少碎句感。
  static const int defaultMinChars = 12;

  /// 合并后的片段最多保留三句，避免为凑长度变成大段朗读。
  static const int maxMergedSentences = 3;

  final int maxChars;
  final int minChars;
  final int maxSentences;

  /// 句末标点（含常见收尾引号/括号），英文句点只在后接空白或结尾时生效，
  /// 避免把小数点、缩写切开。
  static final RegExp _sentenceEnd = RegExp(
    r'(?:[。！？!?；;…]+|\.+(?=\s|$))[”’"）)\]】』」\s]*',
  );

  static final RegExp _softBreak = RegExp(r'[，,、：:；; ]');

  /// 是否含字母（中日韩等表意文字也算）。纯数字/纯标点没有可朗读语义，
  /// Edge TTS 对这类 SSML 会返回空音频导致合成失败、整轮朗读卡住。
  static final RegExp _letter = RegExp(r'\p{L}', unicode: true);

  List<TtsTextSegment> split(String paragraph) {
    // 同长度替换，start/end 仍可直接用于原文高亮。
    final text = normalizePunctuation(paragraph.trim());
    if (text.isEmpty) return const [];
    // 正文末尾单独成行的页码/数字（如「12」「- 3 -」）直接跳过，
    // 交给引擎会合成失败并让本章卡住，不产生任何朗读片段。
    if (!_letter.hasMatch(text)) return const [];

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
    return _mergeShortSegments(segments, text);
  }

  /// 半角标点归一为中文全角：字符数不变，朗读停顿更自然。
  static String normalizePunctuation(String text) => text
      .replaceAll(',', '，')
      .replaceAll(';', '；')
      .replaceAll(':', '：')
      .replaceAll('?', '？')
      .replaceAll('!', '！');

  /// 合并相邻短片段：仅当上一段偏短、合并后不超长且句数仍受控时执行。
  List<TtsTextSegment> _mergeShortSegments(
    List<TtsTextSegment> segments,
    String text,
  ) {
    if (segments.length < 2) return segments;
    final merged = <TtsTextSegment>[segments.first];
    for (var i = 1; i < segments.length; i++) {
      final segment = segments[i];
      final previous = merged.last;
      final raw = text.substring(previous.start, segment.end);
      final previousLength = previous.end - previous.start;
      final combinedLength = segment.end - previous.start;
      final sentenceCount = _sentenceEnd.allMatches(raw).length;
      final canMerge = previousLength < minChars &&
          combinedLength <= maxChars &&
          sentenceCount <= maxMergedSentences;
      if (!canMerge) {
        merged.add(segment);
        continue;
      }
      final trimmed = raw.trim();
      if (trimmed.isEmpty) {
        merged.add(segment);
        continue;
      }
      final offset = raw.indexOf(trimmed);
      merged[merged.length - 1] = TtsTextSegment(
        trimmed,
        previous.start + offset,
        previous.start + offset + trimmed.length,
      );
    }
    return merged;
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
