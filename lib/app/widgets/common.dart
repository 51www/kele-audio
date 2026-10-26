import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// 通用视觉件：卡片 / 标题 / 里程碑标签 / 空态。
///
/// 所有颜色都取自 `Theme` 与 [AppTokens]，页面里不出现任何色值。
class KeleCard extends StatelessWidget {
  const KeleCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.gradient,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Gradient? gradient;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        gradient: gradient ?? tokens.cardGradient,
        borderRadius: BorderRadius.circular(tokens.radiusMd),
        border: Border.all(color: tokens.hairlineColor),
      ),
      child: child,
    );
    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(tokens.radiusMd),
        child: card,
      ),
    );
  }
}

/// 分区标题：左侧短竖条 + 标题（`docs/theme.md` 的结构语言）。
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(0, tokens.spaceLg, 0, tokens.spaceSm),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 16,
            decoration: BoxDecoration(
              gradient: tokens.accentGradient,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(title, style: tokens.sectionStyle)),
          ?trailing,
        ],
      ),
    );
  }
}

/// 里程碑 / 阶段标签（如「M3 接入」）。
class StageTag extends StatelessWidget {
  const StageTag(this.label, {super.key, this.tone = StageTone.quiet});

  final String label;
  final StageTone tone;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (tone) {
      StageTone.quiet => (
          scheme.onSurface.withValues(alpha: 0.06),
          scheme.onSurfaceVariant,
        ),
      StageTone.accent => (scheme.primary.withValues(alpha: 0.14), scheme.primary),
      StageTone.done => (scheme.secondary.withValues(alpha: 0.16), scheme.secondary),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(tokens.radiusPill),
      ),
      child: Text(label, style: tokens.captionStyle.copyWith(color: fg)),
    );
  }
}

enum StageTone { quiet, accent, done }

/// 页面头：大标题 + 一句话说明。
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.subtitle, this.actions});

  final String title;
  final String? subtitle;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spaceMd,
        tokens.spaceMd,
        tokens.spaceMd,
        tokens.spaceXs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: tokens.displayStyle),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(subtitle!, style: tokens.captionStyle),
                ],
              ],
            ),
          ),
          ...?actions,
        ],
      ),
    );
  }
}

/// 空态：图标 + 文案 + 主行动。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        // M8：发现页新增 Banner 后错误态可用高度变小，
        // 空态/错误态改为「居中 + 不足时可滚动」，任何父级高度都不溢出。
        child: ConstrainedBox(
          constraints: BoxConstraints(
            // 无界父级（如 ListView 内嵌空态）不注入 minHeight
            minHeight: constraints.hasBoundedHeight ? constraints.maxHeight : 0,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: scheme.onSurface.withValues(alpha: 0.06),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 34, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                Text(title, style: tokens.titleStyle.copyWith(fontSize: 17)),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: tokens.bodyStyle,
                ),
                if (actionLabel != null) ...[
                  const SizedBox(height: 20),
                  FilledButton(onPressed: onAction, child: Text(actionLabel!)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
