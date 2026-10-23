import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/theme/theme_controller.dart';
import '../../../app/widgets/common.dart';

/// 设置页（PRD §5.6.4）。
///
/// M1 已实装：主题模式（接入 M1 主题体系，立即生效 + 重启保留）；
/// 其余设置项在 M2 / M5 / M8 接入对应能力。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final theme = context.watch<ThemeController>();

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
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
                    Icon(Icons.palette_outlined,
                        size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(child: Text('外观', style: tokens.sectionStyle)),
                    const StageTag('已实装', tone: StageTone.done),
                  ],
                ),
                const SizedBox(height: 12),
                Text('主题模式', style: tokens.captionStyle),
                const SizedBox(height: 8),
                SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: [
                    for (final m in const [
                      ThemeMode.system,
                      ThemeMode.light,
                      ThemeMode.dark,
                    ])
                      ButtonSegment(
                        value: m,
                        label: Text(ThemeController.labelOf(m)),
                      ),
                  ],
                  selected: {theme.mode},
                  onSelectionChanged: (s) => theme.setMode(s.first),
                ),
                const SizedBox(height: 8),
                Text(
                  '儿童模式优先级高于此项（M6 接入）。',
                  style: tokens.captionStyle,
                ),
              ],
            ),
          ),
          SizedBox(height: tokens.spaceMd),
          const _PendingCard(
            title: '播放',
            stage: 'M2',
            items: [
              ('默认音质', '64k / 132k / 192k'),
              ('默认播放模式', '顺序 / 列表循环 / 单曲循环'),
              ('后台自动播放下一章', '开 / 关'),
            ],
            note: '接入播放核心后写入配置并立即生效。',
          ),
          SizedBox(height: tokens.spaceMd),
          const _PendingCard(
            title: '下载',
            stage: 'M8',
            items: [
              ('仅 Wi-Fi 下载', '开 / 关'),
              ('缓存目录', '应用私有目录 audio_cache/'),
            ],
            note: '离线缓存里程碑实现。',
          ),
          SizedBox(height: tokens.spaceMd),
          const _PendingCard(
            title: '缓存',
            stage: 'M5',
            items: [
              ('清除图片缓存', '封面图缓存'),
              ('清除本地数据', '收藏 / 历史 / 日志'),
            ],
            note: '清理入口在 M5 设置页接线。',
          ),
        ],
      ),
    );
  }
}

class _PendingCard extends StatelessWidget {
  const _PendingCard({
    required this.title,
    required this.stage,
    required this.items,
    required this.note,
  });

  final String title;
  final String stage;
  final List<(String, String)> items;
  final String note;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;

    return KeleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lock_clock_rounded, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: tokens.sectionStyle)),
              StageTag(stage, tone: StageTone.accent),
            ],
          ),
          const SizedBox(height: 8),
          for (final (label, value) in items)
            Opacity(
              opacity: 0.72,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(child: Text(label, style: tokens.bodyStyle)),
                    Text(value, style: tokens.captionStyle),
                    const SizedBox(width: 6),
                    Icon(Icons.chevron_right_rounded,
                        size: 18, color: tokens.onHairline),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 6),
          Text(note, style: tokens.captionStyle),
        ],
      ),
    );
  }
}
