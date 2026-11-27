/// MiMo 朗读文本切片。
///
/// 已知 MiMo 长输入会多读音节（同段文本时长抖动极大），因此每片严格限长：
/// 1. 优先在 `。！？…；` 与换行处断开，标点跟随前一句；
/// 2. 单句超长时降级到 `，、`；
/// 3. 仍超长才硬切，硬切点尽量避开引号内部与数字中间。
///
/// 切片不丢字（只在片首尾裁剪空白），保证朗读内容完整。
class MimoTextSplitter {
  const MimoTextSplitter({this.maxChars = defaultMaxChars});

  static const int defaultMaxChars = 150;

  /// 每片上限（字符数）。
  final int maxChars;

  static const String _primary = '。！？!?…；;\n';
  static const String _secondary = '，、,';
  static const int _maxCutBacktrack = 16;

  bool get _validLimit => maxChars > 4;

  /// 按完整句子切成不超过 [maxChars] 的片。
  List<String> split(String text) {
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (normalized.trim().isEmpty) return const [];
    final limit = _validLimit ? maxChars : defaultMaxChars;
    final atoms = _segment(normalized, primary: true);
    final chunks = <String>[];
    final buffer = StringBuffer();

    void flush() {
      final piece = buffer.toString().trim();
      if (piece.isNotEmpty) chunks.add(piece);
      buffer.clear();
    }

    for (final atom in atoms) {
      final trimmed = atom.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.length > limit) {
        // 整句超长：先冲掉已攒的上下文，再把超长句单独切碎。
        flush();
        chunks.addAll(_splitLong(trimmed, limit));
        continue;
      }
      final pending = buffer.toString();
      if (pending.length + trimmed.length > limit) flush();
      buffer.write(trimmed);
    }
    flush();
    return chunks;
  }

  /// 时长异常重试时用：把一片再切成更短的两片（优先就近逗号/顿号）。
  ///
  /// 无法安全切分（仅一个字等）时返回原片，调用方按「无法重试」处理。
  List<String> splitInTwo(String text) {
    final source = text.trim();
    if (source.length < 4) return [source];
    final mid = source.length ~/ 2;
    final depth = _quoteDepthMap(source);
    int? best;
    for (var i = 1; i < source.length; i++) {
      if (depth[i] != 0) continue;
      if (!_secondary.contains(source[i - 1])) continue;
      if (_betweenDigits(source, i)) continue;
      if (best == null || (i - mid).abs() < (best - mid).abs()) best = i;
    }
    if (best != null) {
      final left = source.substring(0, best).trim();
      final right = source.substring(best).trim();
      if (left.isNotEmpty && right.isNotEmpty) return [left, right];
    }
    final cut = _safeHardCut(source, mid, depth, 0);
    if (cut <= 0 || cut >= source.length) return [source];
    final left = source.substring(0, cut).trim();
    final right = source.substring(cut).trim();
    if (left.isEmpty || right.isEmpty) return [source];
    return [left, right];
  }

  // ------------------------------------------------------------------ 句子

  /// 按一级（句末）/ 二级（句内）标点切成小段，标点留在前一段。
  List<String> _segment(String text, {required bool primary}) {
    final pieces = <String>[];
    final depth = _quoteDepthMap(text);
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      final boundarySet = primary ? _primary : '$_primary$_secondary';
      if (!boundarySet.contains(ch)) continue;
      if (depth[i] != 0) continue;
      // 收拢连续的句末标点（例如「？！。」），避免产生空片。
      var end = i + 1;
      while (end < text.length &&
          boundarySet.contains(text[end]) &&
          depth[end] == 0) {
        end++;
      }
      pieces.add(text.substring(start, end));
      start = end;
      i = end - 1;
    }
    if (start < text.length) pieces.add(text.substring(start));
    return pieces;
  }

  /// 超长单句：先按逗号/顿号成句，再对仍超长的片段硬切。
  List<String> _splitLong(String sentence, int limit) {
    final clauses = _segment(sentence, primary: false);
    final chunks = <String>[];
    final buffer = StringBuffer();

    void flush() {
      final piece = buffer.toString().trim();
      if (piece.isNotEmpty) chunks.add(piece);
      buffer.clear();
    }

    for (final clause in clauses) {
      final trimmed = clause.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.length > limit) {
        flush();
        chunks.addAll(_hardCut(trimmed, limit));
        continue;
      }
      final pending = buffer.toString();
      if (pending.length + trimmed.length > limit) flush();
      buffer.write(trimmed);
    }
    flush();
    return chunks;
  }

  /// 按固定上限硬切，切点回退到引号外、且不落在数字中间。
  List<String> _hardCut(String text, int limit) {
    final depth = _quoteDepthMap(text);
    final chunks = <String>[];
    var start = 0;
    while (start < text.length) {
      final remaining = text.length - start;
      if (remaining <= limit) {
        final tail = text.substring(start).trim();
        if (tail.isNotEmpty) chunks.add(tail);
        break;
      }
      final desired = start + limit;
      final cut = _safeHardCut(text, desired, depth, start + 1);
      final end = cut > start ? cut : desired;
      final piece = text.substring(start, end).trim();
      if (piece.isNotEmpty) chunks.add(piece);
      start = end;
      // 跳过切点后的空白，避免下一片以空格开头。
      while (start < text.length && text[start].trim().isEmpty) {
        start++;
      }
    }
    return chunks;
  }

  /// 从 [desired] 向前找安全切点（引号外、数字不拆开、不拆代理对）。
  int _safeHardCut(
    String text,
    int desired,
    List<int> depth,
    int lowerBound,
  ) {
    if (desired >= text.length) return text.length;
    var cut = desired;
    // 不拆开数字：切点两侧都是数字时向前挪。
    while (cut > lowerBound &&
        cut < text.length &&
        _isDigit(text[cut - 1]) &&
        _isDigit(text[cut])) {
      cut--;
    }
    // 不拆代理对。
    if (cut > lowerBound && cut < text.length && _isLowSurrogate(text[cut])) {
      cut--;
    }
    for (var i = cut; i >= lowerBound; i--) {
      final pos = i;
      if (pos <= 0 || pos >= text.length) continue;
      if (depth[pos - 1] == 0 && depth[pos] == 0) {
        if (pos > 0 && _isLowSurrogate(text[pos])) continue;
        return pos;
      }
      if (desired - pos > _maxCutBacktrack) break;
    }
    return cut > lowerBound ? cut : desired;
  }

  // ------------------------------------------------------------------ 工具

  static bool _isDigit(String ch) {
    final code = ch.codeUnitAt(0);
    return code >= 0x30 && code <= 0x39;
  }

  static bool _isLowSurrogate(String ch) {
    final code = ch.codeUnitAt(0);
    return code >= 0xDC00 && code <= 0xDFFF;
  }

  static bool _betweenDigits(String text, int index) =>
      index > 0 &&
      index < text.length &&
      _isDigit(text[index - 1]) &&
      _isDigit(text[index]);

  /// 计算每个「间隙」位置（index 表示 text[index-1] 之后）的引号深度。
  static List<int> _quoteDepthMap(String text) {
    final depth = List<int>.filled(text.length + 1, 0);
    var current = 0;
    var asciiDouble = false;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch == '“' || ch == '「' || ch == '『' || ch == '‘') {
        current++;
      } else if (ch == '”' || ch == '」' || ch == '』') {
        if (current > 0) current--;
      } else if (ch == '’') {
        if (current > 0) current--;
      } else if (ch == '"') {
        asciiDouble = !asciiDouble;
        current += asciiDouble ? 1 : -1;
        if (current < 0) current = 0;
      }
      depth[i + 1] = current;
    }
    return depth;
  }
}
