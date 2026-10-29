import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'progress_ring.dart';

/// 圆形封面 + 贴合外轮廓的进度环 + 播放/暂停状态徽标。
///
/// 三层视觉互不遮挡：
/// - 进度环画在封面**外侧**——[ProgressRing] 的内容区比外径小 2×(环宽+缝隙)，
///   环内缘与圆形封面之间始终留出 [gap] 的缝隙，进度满圈也不会压住封面；
/// - 封面按 `BoxFit.cover` 铺满正方形内容区后再 `ClipOval` 裁成圆，
///   任意长宽比的封面图都居中裁切，不拉伸、不露白边；
/// - 状态徽标压在封面右下角且整块落在环内缘以内，不侵入进度环的描边带。
///
/// 播放态与暂停态一眼可分：
/// - 播放：环外一圈呼吸光晕（明暗/半径随周期起伏）+ 徽标里三根交替起伏的
///   等化器柱 + 封面保持原色；
/// - 暂停：无光晕、进度弧降为半透明、封面盖一层暗色遮罩、徽标换成静态 ⏸。
class CoverProgressAvatar extends StatefulWidget {
  const CoverProgressAvatar({
    super.key,
    required this.coverUrl,
    required this.progress,
    required this.playing,
    required this.background,
    required this.foreground,
    required this.accent,
    this.size = 42,
    this.strokeWidth = 2.5,
    this.gap = 2,
  }) : assert(size > 0, 'size 必须为正'),
       assert(strokeWidth > 0, 'strokeWidth 必须为正'),
       assert(gap >= 0, 'gap 不能为负');

  /// 封面图地址；空串或加载失败时退化为耳机占位。
  final String coverUrl;

  /// 0~1，已完成比例（播放条里是当前章节已播比例）。
  final double progress;
  final bool playing;

  /// 底色（播放条里是反相胶囊的底色）——暂停态徽标的底色来源。
  final Color background;

  /// 前景色——进度轨道与占位图标的来源色。
  final Color foreground;

  /// 强调色——进度弧、播放光晕、播放态徽标底色。
  final Color accent;

  /// 环外径（含描边）。
  final double size;

  /// 环线宽。
  final double strokeWidth;

  /// 环与封面的缝隙。
  final double gap;

  /// 封面正方形边长：外径 - 2×(环宽 + 缝隙)，保证环永远落在封面之外。
  double get coverSize => size - (strokeWidth + gap) * 2;

  @override
  State<CoverProgressAvatar> createState() => _CoverProgressAvatarState();
}

class _CoverProgressAvatarState extends State<CoverProgressAvatar>
    with SingleTickerProviderStateMixin {
  /// 播放态循环动画：同一相位驱动「光晕呼吸」与「等化器柱起伏」，
  /// 两者节奏一致，视觉上像一个整体在呼吸，而不是两块各动各的。
  late final AnimationController _cycle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) _cycle.repeat();
  }

  @override
  void didUpdateWidget(covariant CoverProgressAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing == oldWidget.playing) return;
    // 暂停只停表、不重置相位：恢复播放从当前位置继续，不会跳帧。
    if (widget.playing) {
      _cycle.repeat();
    } else {
      _cycle.stop();
    }
  }

  @override
  void dispose() {
    _cycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ring = _buildRing(context);
    // 暂停态没有呼吸动画，直接返回静态环（省掉每帧重建）
    if (!widget.playing) return ring;

    return AnimatedBuilder(
      animation: _cycle,
      // 进度环 + 封面作为 child 传入：光晕每帧重绘时不重建封面子树
      child: ring,
      builder: (context, child) {
        final breath = 0.5 - 0.5 * math.cos(2 * math.pi * _cycle.value);
        return DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: widget.accent.withValues(alpha: 0.20 + 0.26 * breath),
                blurRadius: 8 + 4 * breath,
                spreadRadius: 0.5 + 1.5 * breath,
              ),
            ],
          ),
          child: child,
        );
      },
    );
  }

  Widget _buildRing(BuildContext context) {
    return ProgressRing(
      value: widget.progress,
      size: widget.size,
      strokeWidth: widget.strokeWidth,
      gap: widget.gap,
      // 暂停态压暗进度弧：位置信息仍可读（还能看出播到哪），但不再抢眼
      color: widget.playing
          ? widget.accent
          : widget.accent.withValues(alpha: 0.7),
      trackColor: widget.foreground.withValues(alpha: 0.18),
      child: SizedBox(
        width: widget.coverSize,
        height: widget.coverSize,
        child: Stack(
          children: [
            Positioned.fill(child: ClipOval(child: _buildCover(context))),
            if (!widget.playing) Positioned.fill(child: _pausedVeil(context)),
            // 徽标圆心到封面圆心的距离 < 封面半径 - 徽标半径：
            // 整块落在圆内，也不会遮住外圈的进度环。
            Positioned(
              right: widget.coverSize * 0.14,
              bottom: widget.coverSize * 0.14,
              child: _buildChip(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCover(BuildContext context) {
    if (widget.coverUrl.isEmpty) return _placeholder();

    // 按显示尺寸解码：封面原图动辄 1000+ 像素，播放条只需几十 dp，
    // 不限制解码宽会在列表滚动时白白吃掉内存。
    final decodeWidth = (widget.size * MediaQuery.devicePixelRatioOf(context))
        .round();

    return Image.network(
      widget.coverUrl,
      fit: BoxFit.cover,
      cacheWidth: decodeWidth,
      // 换章换封面时先保留上一帧，避免闪一下占位图
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => _placeholder(),
    );
  }

  /// 无封面 / 加载失败时的圆形占位。
  Widget _placeholder() => Container(
    color: widget.foreground.withValues(alpha: 0.16),
    alignment: Alignment.center,
    child: Icon(
      Icons.headphones_rounded,
      size: widget.coverSize * 0.45,
      color: widget.foreground.withValues(alpha: 0.8),
    ),
  );

  /// 暂停蒙版：压在封面上的一层中性遮罩，把封面压暗到一眼可辨「没在播」。
  ///
  /// 用 `colorScheme.scrim` 而不是底色/前景色：播放条是反相胶囊，
  /// 「底色」在深色主题里是暖白、在浅色主题里是深棕，拿它做遮罩会一边变暗
  /// 一边发白；scrim 在所有主题里都是暗色，压暗语义才一致。
  Widget _pausedVeil(BuildContext context) => IgnorePointer(
    child: DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.45),
      ),
    ),
  );

  Widget _buildChip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CoverStateChip(
      playing: widget.playing,
      cycle: _cycle,
      // 徽标随封面等比缩放：默认 33 的封面得到 ~14 的徽标，
      // 换更大的尺寸（详情页/大屏）时比例不变，不会缩成一粒小点。
      size: widget.coverSize * 0.42,
      // 播放态用强调色实心徽标（在封面上一眼跳出）；
      // 暂停态退回底色 + 前景色，安静地说明「停着」。
      background: widget.playing
          ? widget.accent
          : widget.background.withValues(alpha: 0.88),
      foreground: widget.playing ? scheme.onPrimary : widget.foreground,
    );
  }
}

/// 播放/暂停状态徽标：圆形底 + 图形。
///
/// 播放态画三根交替起伏的等化器柱（循环动画），暂停态画静态 ⏸；
/// 两种形态尺寸一致，切换时外层布局不跳动。
class CoverStateChip extends StatelessWidget {
  const CoverStateChip({
    super.key,
    required this.playing,
    required this.cycle,
    required this.background,
    required this.foreground,
    this.size = 14,
  });

  final bool playing;

  /// 0~1 循环相位，仅播放态使用。
  final Animation<double> cycle;
  final Color background;
  final Color foreground;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: playing ? '正在播放' : '已暂停',
      child: SizedBox(
        width: size,
        height: size,
        child: DecoratedBox(
          decoration: BoxDecoration(shape: BoxShape.circle, color: background),
          child: Center(
            child: playing
                ? AnimatedBuilder(
                    animation: cycle,
                    builder: (context, _) => CustomPaint(
                      size: Size.square(size * 0.57),
                      painter: _EqualizerPainter(
                        phase: cycle.value,
                        color: foreground,
                      ),
                    ),
                  )
                : Icon(
                    Icons.pause_rounded,
                    size: size * 0.64,
                    color: foreground,
                  ),
          ),
        ),
      ),
    );
  }
}

/// 等化器柱：3 根等宽圆角柱，相位各错开 1/3 周期，底部对齐、高度起伏。
class _EqualizerPainter extends CustomPainter {
  const _EqualizerPainter({required this.phase, required this.color});

  static const int _barCount = 3;

  /// 0~1 循环相位。
  final double phase;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final gap = size.width * 0.13;
    final barWidth = (size.width - gap * (_barCount - 1)) / _barCount;
    final radius = Radius.circular(barWidth / 2);

    for (var i = 0; i < _barCount; i++) {
      // cos 波形 + 每根错开 1/3 周期：三根柱此起彼伏，而不是整齐上下
      final wave = 0.5 - 0.5 * math.cos(2 * math.pi * (phase + i / _barCount));
      final height = size.height * (0.30 + 0.70 * wave);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            i * (barWidth + gap),
            size.height - height,
            barWidth,
            height,
          ),
          radius,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_EqualizerPainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.color != color;
}
