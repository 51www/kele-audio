import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/widgets/common.dart';

/// 二级页占位骨架：标题 + 阶段标签 + 该页要交付的内容清单。
///
/// M1 只保证**路由可达、可返回、MiniPlayer 不丢**（准出条件），
/// 实装放在对应里程碑。
class StageStubPage extends StatelessWidget {
  const StageStubPage({
    super.key,
    required this.title,
    required this.stage,
    required this.summary,
    this.points = const [],
    this.note,
    this.extra,
  });

  final String title;

  /// 所属里程碑，如 `M5` / `M8`；空串表示已实装。
  final String stage;
  final String summary;
  final List<String> points;
  final String? note;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          tokens.spaceMd,
          tokens.spaceSm,
          tokens.spaceMd,
          tokens.spaceLg,
        ),
        children: [
          KeleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.timeline_rounded,
                        size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(child: Text('这一页要做的事', style: tokens.sectionStyle)),
                    if (stage.isNotEmpty) StageTag(stage, tone: StageTone.accent),
                  ],
                ),
                const SizedBox(height: 8),
                Text(summary, style: tokens.bodyStyle),
                if (points.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  for (final p in points)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.check_rounded,
                              size: 16, color: scheme.secondary),
                          const SizedBox(width: 8),
                          Expanded(child: Text(p, style: tokens.bodyStyle)),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
          if (extra != null) ...[SizedBox(height: tokens.spaceMd), extra!],
          if (note != null) ...[
            SizedBox(height: tokens.spaceMd),
            Text(note!, style: tokens.captionStyle),
          ],
        ],
      ),
    );
  }
}
