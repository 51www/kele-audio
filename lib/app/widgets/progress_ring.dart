import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 环形进度外框：在 [child] 外圈画一圈进度环。
///
/// 语义：`value` 是 0~1 的完成度（播放条里是「当前章节已播比例」）。
/// - `value <= 0`：只画轨道环（完整的一圈底环），不画进度弧 ——
///   避免圆头端帽在 0% 处留下一个孤立的圆点；
/// - `value >= 1`：画整圆（`StrokeCap.butt`），闭合处不会叠出小凸起；
/// - 中间值：从 [startAngle] 起、按 [clockwise] 方向画扫过 `value * 2π` 的弧。
///
/// 颜色默认取主题 `colorScheme.primary`，轨道色默认取当前前景色的
/// 16% 透明度 —— 播放条是「反相胶囊」（浅色主题深底、深色主题白底），
/// 用前景色做轨道在两种反相下都成立。
///
/// [value] 变化时用 [TweenAnimationBuilder] 做插值过渡（从当前显示值
/// 平滑走到新值），所以每秒一次的 tick 不会让环跳动。
class ProgressRing extends StatefulWidget {
  const ProgressRing({
    super.key,
    required this.value,
    required this.child,
    this.size = 42,
    this.strokeWidth = 2.5,
    this.gap = 1.5,
    this.color,
    this.trackColor,
    this.startAngle = -math.pi / 2,
    this.clockwise = true,
    this.duration = const Duration(milliseconds: 320),
    this.curve = Curves.easeOutCubic,
    this.cap = StrokeCap.round,
  }) : assert(size > 0, 'size 必须为正'),
       assert(strokeWidth > 0, 'strokeWidth 必须为正'),
       assert(gap >= 0, 'gap 不能为负'),
       assert(size > (strokeWidth + gap) * 2, '环宽 + 间隙过大，留不出内容区');

  /// 进度，0~1；越界自动 clamp，NaN/Infinity 视为 0。
  final double value;

  /// 环内内容（封面、图标等），按「外径 - 2×(环宽+间隙)」的正方形排版。
  final Widget child;

  /// 环外径（含描边），单位 dp。
  final double size;

  /// 环线宽，单位 dp。建议 2~3：再细会糊，再粗压过内容。
  final double strokeWidth;

  /// 环与内容的间隙，单位 dp。
  final double gap;

  /// 进度弧颜色，默认 `colorScheme.primary`。
  final Color? color;

  /// 轨道（未完成部分）颜色，默认前景色 16%。
  final Color? trackColor;

  /// 起始角度（弧度），默认 -π/2 即 12 点方向。
  final double startAngle;

  /// 是否顺时针增长，默认 true。
  final bool clockwise;

  /// 进度变化的过渡时长；`Duration.zero` 表示不做动画。
  final Duration duration;

  final Curve curve;

  /// 进度弧的端帽样式（100% 时强制 butt）。
  final StrokeCap cap;

  @override
  State<ProgressRing> createState() => _ProgressRingState();
}

class _ProgressRingState extends State<ProgressRing> {
  /// 上一次的目标进度，用于识别「换章/重置」造成的大幅回退。
  double _lastTarget = 0;

  double get _target {
    final raw = widget.value.isFinite ? widget.value : 0.0;
    return raw.clamp(0.0, 1.0).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final progressColor = widget.color ?? scheme.primary;
    final ringTrackColor =
        widget.trackColor ?? scheme.onSurface.withValues(alpha: 0.16);

    final target = _target;
    // 换章 / 重置：进度从接近满圈直接回到开头时不做插值，
    // 否则玩家会看到进度环「倒放」一整圈。
    final isReset = target < _lastTarget - 0.5;
    _lastTarget = target;

    final content = SizedBox(
      width: widget.size - (widget.strokeWidth + widget.gap) * 2,
      height: widget.size - (widget.strokeWidth + widget.gap) * 2,
      child: Center(child: widget.child),
    );

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: target),
        duration: isReset ? Duration.zero : widget.duration,
        curve: widget.curve,
        builder: (context, animated, _) => CustomPaint(
          painter: _ProgressRingPainter(
            value: animated,
            color: progressColor,
            trackColor: ringTrackColor,
            strokeWidth: widget.strokeWidth,
            startAngle: widget.startAngle,
            clockwise: widget.clockwise,
            cap: widget.cap,
          ),
          child: content,
        ),
      ),
    );
  }
}

class _ProgressRingPainter extends CustomPainter {
  const _ProgressRingPainter({
    required this.value,
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
    required this.startAngle,
    required this.clockwise,
    required this.cap,
  });

  /// 已 clamp 到 0~1。
  final double value;
  final Color color;
  final Color trackColor;
  final double strokeWidth;
  final double startAngle;
  final bool clockwise;
  final StrokeCap cap;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    // 描边中心线半径：外缘正好落在 size 边界内，不会被裁切
    final radius = (size.shortestSide - strokeWidth) / 2;
    if (radius <= 0) return;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = trackColor,
    );

    // 0%：只有轨道环，不画进度（圆头端帽会在起点留一个孤点）
    if (value <= 0) return;

    final progressPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = color;

    // 100%：整圆绘制，闭合无缝（圆头端帽在满圈时会叠出凸起）
    if (value >= 1) {
      canvas.drawCircle(
        center,
        radius,
        progressPaint..strokeCap = StrokeCap.butt,
      );
      return;
    }

    final sweep = 2 * math.pi * value * (clockwise ? 1 : -1);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweep,
      false,
      progressPaint..strokeCap = cap,
    );
  }

  @override
  bool shouldRepaint(_ProgressRingPainter old) =>
      old.value != value ||
      old.color != color ||
      old.trackColor != trackColor ||
      old.strokeWidth != strokeWidth ||
      old.startAngle != startAngle ||
      old.clockwise != clockwise ||
      old.cap != cap;
}
