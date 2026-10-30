import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderAbstractViewport, RenderProxyBox, ScrollDirection;

import '../../app/theme/app_tokens.dart';
import '../../core/api/subtitle_source.dart';

/// 文稿正文：整段滚动 + **跟随播放进度高亮**。
///
/// 视觉设计（「朗读卷轴」语言，对齐暖纸书卷主题气质）：
/// - 每句水平居中，如诗行竖读；未高亮句用 [AppTokens.bodyStyle] 15/1.7；
/// - 当前句是唯一焦点：主题色文字（w600）+ 低饱和品牌色衬底圆角块；
///   [AnimatedDefaultTextStyle] / [AnimatedContainer] 250ms 平滑过渡；
/// - 距当前句 2 行以外的句子降到 0.68 不透明度，歌词式渐次聚焦；
/// - 当前句自动滚动停在视口 40% 高度（视线略在前方）；
/// - 用户手动滚动后**暂停跟随 4s**，静置后自动恢复，不与手势抢滚动；
/// - 首帧定位 / 切章重载：直接 `jumpTo` 当前句（不播滚动动画）。
///
/// 位置来源 [positionTick]（`PlayerService.positionTick`，4Hz 高频通知）：
/// 只在「当前句索引变化」时 setState，不随高频刷新整段重建。
/// 仍为仅浏览：点击句子不 seek（PRD 范围收口）。
class TranscriptBody extends StatefulWidget {
  const TranscriptBody({
    super.key,
    required this.cues,
    required this.positionTick,
  });

  /// 本章文稿（`SubtitleSource` 保证已按 `fromSec` 升序）
  final List<SubtitleCue> cues;

  /// 播放位置高频通知器（`PlayerService.positionTick`）
  final ValueListenable<Duration> positionTick;

  @override
  State<TranscriptBody> createState() => _TranscriptBodyState();
}

class _TranscriptBodyState extends State<TranscriptBody> {
  static const _animDuration = Duration(milliseconds: 250);

  /// 当前句目标点：视口高度的 40% 处（视线略在前方，不顶着顶部）
  static const double _alignAt = 0.40;

  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _keys = {};

  /// 已实测的句子高度（估算远端偏移用），`index → item 高度`
  final Map<int, double> _heights = {};

  int _active = -1;

  /// 用户手动滚动后暂停跟随的截止时刻
  DateTime _suppressUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// 自身发起的滚动动画进行中（区别于用户手势，避免误判为手动滚动）
  bool _selfScrolling = false;

  @override
  void initState() {
    super.initState();
    widget.positionTick.addListener(_onPositionTick);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _syncPosition(jump: true),
    );
  }

  @override
  void didUpdateWidget(covariant TranscriptBody old) {
    super.didUpdateWidget(old);
    if (old.positionTick != widget.positionTick) {
      old.positionTick.removeListener(_onPositionTick);
      widget.positionTick.addListener(_onPositionTick);
    }
    // 切章（父级会换 key 重建，这里兜底 cues 变化）：清缓存并重新定位
    if (!identical(old.cues, widget.cues)) {
      _keys.clear();
      _heights.clear();
      _active = -1;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _syncPosition(jump: true),
      );
    }
  }

  @override
  void dispose() {
    widget.positionTick.removeListener(_onPositionTick);
    _scroll.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- 位置 → 当前句

  /// `cues` 已按 `fromSec` 升序：取最后一个 `fromSec <= pos` 的句子；
  /// 句间空隙保持上一句高亮，首个句子之前无高亮。
  int _indexFor(Duration pos) {
    if (widget.cues.isEmpty) return -1;
    final sec = pos.inMilliseconds / 1000.0;
    var lo = 0, hi = widget.cues.length - 1, best = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (widget.cues[mid].fromSec <= sec) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return best;
  }

  void _onPositionTick() {
    final idx = _indexFor(widget.positionTick.value);
    if (idx == _active) return;
    setState(() => _active = idx);
    if (idx >= 0 && DateTime.now().isAfter(_suppressUntil)) {
      _bringIntoView(idx, jump: false, force: false);
    }
  }

  /// 首帧/切章定位：直接按当前播放位置计算并跳位。
  void _syncPosition({required bool jump}) {
    if (!mounted) return;
    final idx = _indexFor(widget.positionTick.value);
    if (idx == _active) return;
    setState(() => _active = idx);
    if (idx < 0) return;
    final hadCtx = _keys[idx]?.currentContext != null;
    _bringIntoView(idx, jump: jump, force: true);
    // 估算跳位后目标句已随首帧构建 → 下一帧用真实几何做一次精确校正
    if (!hadCtx) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _active == idx) {
          _bringIntoView(idx, jump: jump, force: true);
        }
      });
    }
  }

  // ------------------------------------------------------------------ 滚动跟随

  void _bringIntoView(int index, {required bool jump, required bool force}) {
    if (!force && _selfScrolling) return;
    final ctx = _keys[index]?.currentContext;
    double target;
    if (ctx != null) {
      // 已渲染（在 viewport 内或 cacheExtent 里）：精确计算
      final ro = ctx.findRenderObject();
      final vp = ro == null ? null : RenderAbstractViewport.maybeOf(ro);
      final reveal = (ro != null && vp != null)
          ? vp.getOffsetToReveal(ro, _alignAt)
          : null;
      target = reveal?.offset ?? _scroll.offset;
    } else {
      // 未渲染（初次定位 / seek 跳远）：按已测高度估算，随后由下一次
      // 高亮切换的 ensureVisible 自然校准（顺序播放时目标句很快被构建）
      target = _estimatedOffset(index);
    }
    _moveTo(target, jump: jump);
  }

  void _moveTo(double target, {required bool jump}) {
    if (!_scroll.hasClients) return;
    final max = math.max(_scroll.position.maxScrollExtent, 0.0);
    final clamped = math.min(math.max(target, 0.0), max);
    if (jump) {
      _scroll.jumpTo(clamped);
      return;
    }
    _selfScrolling = true;
    _scroll
        .animateTo(
          clamped,
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() => _selfScrolling = false);
  }

  /// 估算第 [index] 句的滚动偏移（把该句中心放到视口 [_alignAt] 处）。
  double _estimatedOffset(int index) {
    if (!_scroll.hasClients) return 0;
    final tokens = AppTokens.of(context);
    final sep = tokens.spaceSm;
    var sum = 0.0;
    for (var k = 0; k < index; k++) {
      sum += (_heights[k] ?? _avgHeight()) + sep;
    }
    final h = _heights[index] ?? _avgHeight();
    return tokens.spaceXs + sum + h * 0.5 -
        _scroll.position.viewportDimension * _alignAt;
  }

  double _avgHeight() {
    if (_heights.isEmpty) return 44;
    var total = 0.0;
    for (final h in _heights.values) {
      total += h;
    }
    return total / _heights.length;
  }

  void _recordHeight(int index, double height) {
    if (_heights[index] != height) _heights[index] = height;
  }

  GlobalKey _keyFor(int index) => _keys.putIfAbsent(index, GlobalKey.new);

  // ---------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    // 与环境 DefaultTextStyle 合并字体族等未定字段：
    // tokens 字阶不自带 fontFamily，普通 Text 靠环境合并补齐，但
    // AnimatedDefaultTextStyle 用的是纯 style —— 不合并会丢应用字体。
    final ambient = DefaultTextStyle.of(context).style;
    final base = ambient.merge(
      tokens.bodyStyle.copyWith(fontSize: 15, height: 1.7),
    );
    final activeStyle = base.copyWith(
      color: scheme.primary,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
    );
    // 每项的纵向内边距恒定：高亮切换只变色不跳版
    final itemPadding = EdgeInsets.symmetric(
      vertical: tokens.spaceSm + 2,
      horizontal: tokens.spaceMd,
    );

    return NotificationListener<UserScrollNotification>(
      onNotification: (n) {
        if (_selfScrolling) return false;
        if (n.direction == ScrollDirection.idle) return false;
        // 用户手动滚动：暂停跟随 4s，静置后自动恢复
        _suppressUntil = DateTime.now().add(const Duration(seconds: 4));
        return false;
      },
      child: ListView.separated(
        controller: _scroll,
        padding: EdgeInsets.only(top: tokens.spaceXs, bottom: tokens.spaceLg * 2),
        itemCount: widget.cues.length,
        separatorBuilder: (_, _) => SizedBox(height: tokens.spaceSm),
        itemBuilder: (context, i) {
          final active = i == _active;
          final dist = active ? 0 : (i - _active).abs();
          final opacity = active || _active < 0 || dist <= 1 ? 1.0 : 0.68;
          return _HeightReporter(
            onHeight: (h) => _recordHeight(i, h),
            child: KeyedSubtree(
              key: _keyFor(i),
              child: AnimatedContainer(
                duration: _animDuration,
                curve: Curves.easeOut,
                padding: itemPadding,
                decoration: BoxDecoration(
                  color: active
                      ? scheme.primary.withValues(alpha: 0.07)
                      // 透明占位：与高亮同结构，切换不重建不跳版
                      : scheme.primary.withValues(alpha: 0.0),
                  borderRadius: BorderRadius.circular(tokens.radiusMd),
                ),
                child: AnimatedDefaultTextStyle(
                  duration: _animDuration,
                  curve: Curves.easeOut,
                  style: active ? activeStyle : base,
                  child: AnimatedOpacity(
                    duration: _animDuration,
                    curve: Curves.easeOut,
                    opacity: opacity,
                    child: Text(
                      widget.cues[i].content,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 测句子实际高度（`performLayout` 时旁路回调，不触发 setState），
/// 供远端未渲染句子的偏移估算。
class _HeightReporter extends SingleChildRenderObjectWidget {
  const _HeightReporter({required this.onHeight, required super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHeightReporter()..onHeight = onHeight;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderHeightReporter renderObject,
  ) {
    renderObject.onHeight = onHeight;
  }
}

class _RenderHeightReporter extends RenderProxyBox {
  ValueChanged<double>? _onHeight;
  double _last = -1;

  set onHeight(ValueChanged<double>? value) => _onHeight = value;

  @override
  void performLayout() {
    super.performLayout();
    if (size.height != _last) {
      _last = size.height;
      _onHeight?.call(size.height);
    }
  }
}
