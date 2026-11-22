import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../api/key_value_store.dart';

/// 阅读排版模式（docs/reader-design.md §4.3）。
enum ReaderFlow { paged, scrolled }

extension ReaderFlowX on ReaderFlow {
  String get storageValue => name;

  /// foliate-js `renderer.setAttribute('flow', …)` 的取值。
  String get jsValue => this == ReaderFlow.paged ? 'paginated' : 'scrolled';

  String get label => this == ReaderFlow.paged ? '翻页' : '滚动';

  static ReaderFlow fromStorage(String? value) =>
      value == ReaderFlow.scrolled.storageValue
          ? ReaderFlow.scrolled
          : ReaderFlow.paged;
}

/// 阅读排版设置（`reader_typography`）。
///
/// 只影响阅读页 WebView 内的正文排版，不参与全局主题 token；
/// 字体大小/行距/边距按「阅读舒适区」给出上下限。
class ReaderTypography {
  const ReaderTypography({
    this.fontSize = 17,
    this.lineHeight = 1.8,
    this.margin = 22,
    this.weight = 400,
    this.flow = ReaderFlow.paged,
  });

  /// 正文字号（px）。
  final double fontSize;

  /// 行距倍数。
  final double lineHeight;

  /// 左右边距（px），同时用于翻页模式的可读宽度。
  final double margin;

  /// 字重（400 / 500 / 600）。
  final int weight;

  final ReaderFlow flow;

  static const ReaderTypography defaults = ReaderTypography();

  static const double minFontSize = 14;
  static const double maxFontSize = 26;
  static const double minLineHeight = 1.4;
  static const double maxLineHeight = 2.4;
  static const double minMargin = 0;
  static const double maxMargin = 40;

  ReaderTypography copyWith({
    double? fontSize,
    double? lineHeight,
    double? margin,
    int? weight,
    ReaderFlow? flow,
  }) {
    return ReaderTypography(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      margin: margin ?? this.margin,
      weight: weight ?? this.weight,
      flow: flow ?? this.flow,
    );
  }

  Map<String, dynamic> toJson() => {
    'fontSize': fontSize,
    'lineHeight': lineHeight,
    'margin': margin,
    'weight': weight,
    'flow': flow.storageValue,
  };

  factory ReaderTypography.fromJson(Map<String, dynamic> json) {
    double clamp(double value, double min, double max) =>
        value.clamp(min, max).toDouble();

    final fontSize = (json['fontSize'] as num?)?.toDouble();
    final lineHeight = (json['lineHeight'] as num?)?.toDouble();
    final margin = (json['margin'] as num?)?.toDouble();
    final weight = (json['weight'] as num?)?.toInt();
    return ReaderTypography(
      fontSize: clamp(fontSize ?? 17, minFontSize, maxFontSize),
      lineHeight: clamp(lineHeight ?? 1.8, minLineHeight, maxLineHeight),
      margin: clamp(margin ?? 22, minMargin, maxMargin),
      weight: [400, 500, 600].contains(weight) ? weight! : 400,
      flow: ReaderFlowX.fromStorage(json['flow']?.toString()),
    );
  }
}

/// 排版设置持久化（docs/reader-design.md §2.2 `reader_typography`）。
class ReaderTypographyStore extends ChangeNotifier {
  ReaderTypographyStore(this._kv);

  static const storageKey = 'reader_typography';

  final KeyValueStore _kv;
  ReaderTypography _value = ReaderTypography.defaults;

  ReaderTypography get value => _value;

  Future<void> load() async {
    final raw = _kv.getString(storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _value = ReaderTypography.fromJson(
            Map<String, dynamic>.from(decoded),
          );
        }
      } catch (e) {
        debugPrint('[reader] 读取 reader_typography 失败：$e');
      }
    }
    notifyListeners();
  }

  Future<void> update(ReaderTypography next) async {
    _value = next;
    notifyListeners();
    await _kv.setString(storageKey, jsonEncode(_value.toJson()));
  }

  Future<void> reset() => update(ReaderTypography.defaults);
}
