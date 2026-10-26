import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/theme/theme_controller.dart';
import '../../../app/widgets/common.dart';
import '../../../core/domain/playback.dart';
import '../../../core/services/image_cache_cleaner.dart';
import '../../../core/services/player/player_service.dart';
import '../../../core/services/settings_store.dart';

/// 设置页（PRD §5.6.4，M5 接线）。
///
/// - 主题模式：接入 M1 主题体系（立即生效 + 重启保留）；
/// - 默认音质 / 默认播放模式 / 后台自动播放下一章：接入 M2 播放参数
///   （同一套 PlayerPrefs key，播放页临时切换与这里共享持久化）；
/// - 仅 Wi-Fi 下载：开关先占位持久化（下载能力 M8 实现）；
/// - 清除图片缓存：内存 + 磁盘（Web 端仅内存）。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final theme = context.watch<ThemeController>();
    final player = context.watch<PlayerService>();
    final settings = context.watch<SettingsStore>();

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
          _SectionCard(
            icon: Icons.palette_outlined,
            title: '外观',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
          _SectionCard(
            icon: Icons.play_circle_outline_rounded,
            title: '播放',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('默认音质', style: tokens.captionStyle),
                const SizedBox(height: 8),
                SegmentedButton<AudioQuality>(
                  showSelectedIcon: false,
                  segments: [
                    for (final q in AudioQuality.values)
                      ButtonSegment(value: q, label: Text(q.label)),
                  ],
                  selected: {player.quality},
                  onSelectionChanged: (s) => player.setDefaultQuality(s.first),
                ),
                const SizedBox(height: 6),
                Text(
                  '对之后的取址生效，不会打断正在播放的内容。',
                  style: tokens.captionStyle,
                ),
                const SizedBox(height: 14),
                Text('默认播放模式', style: tokens.captionStyle),
                const SizedBox(height: 8),
                SegmentedButton<PlayMode>(
                  showSelectedIcon: false,
                  segments: [
                    for (final m in PlayMode.values)
                      ButtonSegment(value: m, label: Text(m.label)),
                  ],
                  selected: {player.mode},
                  onSelectionChanged: (s) => player.setMode(s.first),
                ),
                const SizedBox(height: 14),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('后台自动播放下一章'),
                  subtitle: const Text('关闭后本章播完即停（单曲循环不受影响）'),
                  value: player.autoNext,
                  onChanged: (v) => player.setAutoNext(v),
                ),
              ],
            ),
          ),
          SizedBox(height: tokens.spaceMd),
          _SectionCard(
            icon: Icons.download_for_offline_outlined,
            title: '下载',
            trailing: const StageTag('M8'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('仅 Wi-Fi 下载'),
                  subtitle: const Text('开关先记住选择，下载功能 M8 上线'),
                  value: settings.wifiOnlyDownload,
                  onChanged: (v) => settings.setWifiOnlyDownload(v),
                ),
                _kvLine(tokens, '缓存目录', '应用私有目录 audio_cache/'),
              ],
            ),
          ),
          SizedBox(height: tokens.spaceMd),
          _SectionCard(
            icon: Icons.cleaning_services_outlined,
            title: '缓存',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '封面图缓存会随浏览自动重建；收藏、历史与进度不会被清除。',
                  style: tokens.captionStyle,
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: () => _confirmClearImages(context),
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: const Text('清除图片缓存'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearImages(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除图片缓存？'),
        content: const Text('将清空已缓存的封面图，下次浏览时重新下载。\n收藏、历史与进度不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ImageCacheCleaner.clearAll();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('图片缓存已清除')));
  }

  Widget _kvLine(AppTokens tokens, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 72, child: Text(k, style: tokens.captionStyle)),
            Expanded(child: Text(v, style: tokens.captionStyle)),
          ],
        ),
      );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.child,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final Widget? trailing;

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
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: tokens.sectionStyle)),
              ?trailing,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}
