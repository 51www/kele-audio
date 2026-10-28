import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../app/di.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../app/theme/theme_controller.dart';
import '../../../app/widgets/common.dart';
import '../../../app/widgets/theme_preset_picker.dart';
import '../../../core/domain/playback.dart';
import '../../../core/services/bili_account_service.dart';
import '../../../core/services/image_cache_cleaner.dart';
import '../../../core/services/player/player_service.dart';
import '../../../core/services/settings_store.dart';

/// 设置页（PRD §5.6.4，M5 接线）。
///
/// - 儿童模式：开关入口收拢到这里（原发现页顶部开关已移除），
///   开启直接生效（自动套儿童默认主题），关闭走二次确认防误触；
/// - 主题：一般模式 / 儿童模式各一套皮肤（六个预设，默认主题1 / 主题4，立即生效 + 重启保留）；
/// - 默认音质 / 默认播放模式 / 后台自动播放下一章：接入 M2 播放参数
///   （同一套 PlayerPrefs key，播放页临时切换与这里共享持久化）；
/// - 仅 Wi-Fi 下载：开关先占位持久化（下载能力 M8 实现）；
/// - 清除图片缓存：内存 + 磁盘（Web 端仅内存）；
/// - 高级设置：发现页「编辑精选」行显隐 + 分类显隐（「推荐」固定显示）；
/// - 账号绑定：B 站扫码登录（绑定/解绑 + 资料展示，绑定后解锁高音质音源）、
///   WebDAV 占位入口（暂未实现）。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final theme = context.watch<ThemeController>();
    final player = context.watch<PlayerService>();
    final settings = context.watch<SettingsStore>();
    final account = context.watch<BiliAccountService>();

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
            icon: Icons.child_care_rounded,
            title: '儿童模式',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('开启儿童模式'),
                  subtitle: const Text('只展示儿童白名单内容，并自动套用儿童主题'),
                  value: theme.children,
                  onChanged: (v) => _toggleKids(context, theme.children),
                ),
                Text(
                  theme.children
                      ? '儿童模式已开启：发现页只保留儿童分类，搜索入口收起。'
                      : '开启后内容按儿童白名单过滤，不做操作限制。',
                  style: tokens.captionStyle,
                ),
              ],
            ),
          ),
          SizedBox(height: tokens.spaceMd),
          _SectionCard(
            icon: Icons.palette_outlined,
            title: '外观',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ThemePresetPicker(
                  selected: theme.preset,
                  onSelected: theme.setPreset,
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
          SizedBox(height: tokens.spaceMd),
          _SectionCard(
            icon: Icons.tune_rounded,
            title: '高级设置',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('显示编辑精选'), 
                  value: settings.featuredVisible,
                  onChanged: settings.setFeaturedVisible,
                ),
                const SizedBox(height: 6),
                Text('发现页类型显示', style: tokens.captionStyle),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final cat in _controllableCategories(context))
                      FilterChip(
                        label: Text(cat.name),
                        selected: settings.isCategoryVisible(cat.id),
                        onSelected: (v) => settings.setCategoryVisible(cat.id, v),
                      ),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(height: tokens.spaceMd),
          _SectionCard(
            icon: Icons.link_rounded,
            title: '账号绑定',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [  
                _BindingRow(
                  icon: Icons.smart_display_outlined,
                  title: 'B 站账号',
                  subtitle: '绑定后解锁高音质音源',
                  status: account.bound ? '已绑定' : '未绑定',
                  bound: account.bound,
                  onTap: () => context.push('/profile/bili-account'),
                ),
                _BindingRow(
                  icon: Icons.cloud_sync_outlined,
                  title: 'WebDAV',
                  subtitle: '绑定后同步书架与收听进度',
                  status: '未绑定',
                  onTap: () => _notifyPlanned(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 高级设置里可控制显隐的分类：成人分类去掉固定显示的「推荐」。
  List<({String id, String name})> _controllableCategories(BuildContext context) {
    final cats = context.read<AppServices>().content.adultCategories;
    return [
      for (final c in cats)
        if (c.id != SettingsStore.pinnedCategoryId) (id: c.id, name: c.name),
    ];
  }

  /// 账号绑定占位入口的统一反馈（本期不实现）。
  void _notifyPlanned(BuildContext context) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('绑定功能开发中，敬请期待')));
  }

  /// 儿童模式开关（原发现页顶部入口迁入）：开启直接切，
  /// 关闭走二次确认弹层防误触（ThemeController.setChildren 约定）。
  Future<void> _toggleKids(BuildContext context, bool current) async {
    if (current) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('退出儿童模式？'),
          content: const Text('退出后将恢复成人分类与常规内容，主题保持当前选择。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('退出'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (!context.mounted) return;
    await context.read<ThemeController>().setChildren(!current);
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

/// 账号绑定入口行：图标 + 标题/副标题 + 绑定状态，点击进入绑定页
///（WebDAV 暂未实现，点击给开发中提示）。
class _BindingRow extends StatelessWidget {
  const _BindingRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.status,
    required this.onTap,
    this.bound = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String status;
  final bool bound;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(tokens.radiusMd),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: tokens.bodyStyle),
                  const SizedBox(height: 2),
                  Text(subtitle, style: tokens.captionStyle),
                ],
              ),
            ),
            Text(
              status,
              style: tokens.captionStyle.copyWith(
                color: bound ? scheme.primary : null,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, color: tokens.onHairline),
          ],
        ),
      ),
    );
  }
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
