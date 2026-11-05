import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../app/di.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../app/theme/theme_controller.dart';
import '../../../app/widgets/common.dart';
import '../../../app/widgets/theme_preset_picker.dart';
import '../../../core/domain/playback.dart';
import '../../../core/services/backup/backup_delivery.dart';
import '../../../core/services/backup/backup_pick.dart';
import '../../../core/services/backup/backup_service.dart';
import '../../../core/services/bili_account_service.dart';
import '../../../core/services/image_cache_cleaner.dart';
import '../../../core/services/player/player_service.dart';
import '../../../core/services/settings_store.dart';
import 'tts_settings_section.dart';

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
/// - 账号绑定：B 站扫码登录（绑定/解绑 + 资料展示，绑定后解锁高音质音源）；
/// - 数据备份：本机数据打包导出（可选密码加密）/ 从备份文件还原，
///   用于换机、重装后的数据迁移（云端数据不参与迁移）。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final theme = context.watch<ThemeController>();
    final player = context.watch<PlayerService>();
    final settings = context.watch<SettingsStore>();
    final account = context.watch<BiliAccountService>();
    final backup = context.watch<BackupService>();

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
                _QualityPicker(player: player, account: account),
                const SizedBox(height: 8),
                Text(_qualityHint(account), style: tokens.captionStyle),
                const SizedBox(height: 4),
                Text(
                  '切换立即生效并自动续播；Hi-Res 流量约为 192K 的数倍，建议在 Wi-Fi 下使用。',
                  style: tokens.captionStyle.copyWith(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
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
                  subtitle: '绑定解锁 192K，大会员解锁 Hi-Res',
                  status: account.bound
                      ? (account.isVip ? '已绑定·大会员' : '已绑定')
                      : '未绑定',
                  bound: account.bound,
                  onTap: () => context.push('/profile/bili-account'),
                ),
              ],
            ),
          ),
          SizedBox(height: tokens.spaceMd),
          _SectionCard(
            icon: Icons.headphones_rounded,
            title: '本地书 · 听书',
            child: const TtsSettingsSection(),
          ),
          SizedBox(height: tokens.spaceMd),
          _SectionCard(
            icon: Icons.backup_outlined,
            title: '数据备份',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '把设置、书架、历史与进度、统计打包成备份文件，'
                  '用于换机 / 重装后的数据迁移；云端数据不参与迁移。',
                  style: tokens.captionStyle,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed:
                          backup.busy ? null : () => _exportBackup(context),
                      icon: const Icon(Icons.file_upload_outlined, size: 18),
                      label: const Text('导出备份'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed:
                          backup.busy ? null : () => _importBackup(context),
                      icon: const Icon(Icons.file_download_outlined, size: 18),
                      label: const Text('导入备份'),
                    ),
                  ],
                ),
                if (backup.busy) ...[
                  const SizedBox(height: 12),
                  const Center(child: LinearProgressIndicator()),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- 数据备份

  /// 导出：弹窗设密码（留空=明文）→ 生成文件 → 平台交付
  /// （Web 下载 / 移动端分享面板 / 桌面另存为）。
  Future<void> _exportBackup(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final service = context.read<BackupService>();
    final password = await _askExportPassword(context);
    if (password == null) return; // 用户取消

    try {
      final bytes = await service.buildBackup(
        password: password.isEmpty ? null : password,
      );
      final delivered = await deliverBackupFile(
        suggestedBackupFileName(DateTime.now()),
        bytes,
      );
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(delivered ? '备份已导出' : '已取消导出'),
        ));
    } on UnsupportedError {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('当前平台不支持导出备份文件')));
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
  }

  /// 导入：选文件 → 解析校验（加密文件弹密码框重试）→ 逐项确认覆盖 →
  /// 确认后整批写回并即时生效。任一步取消/失败本机数据不变。
  Future<void> _importBackup(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final service = context.read<BackupService>();
    final bytes = await pickBackupFile();
    if (bytes == null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('已取消导入')));
      return;
    }

    StagedImport staged;
    String? password;
    while (true) {
      try {
        staged = await service.parseImport(bytes, password: password);
        break;
      } on BackupFailure catch (f) {
        final wantsPassword = f.kind == BackupFailureKind.needsPassword ||
            f.kind == BackupFailureKind.wrongPassword;
        if (!wantsPassword || !context.mounted) {
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(
              content: Text(wantsPassword ? '已取消导入' : f.message),
            ));
          return;
        }
        final retry = await _askImportPassword(
          context,
          firstAttempt: f.kind == BackupFailureKind.needsPassword,
        );
        if (retry == null) {
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(const SnackBar(content: Text('已取消导入')));
          return;
        }
        password = retry;
      } catch (e) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('导入失败：$e')));
        return;
      }
    }

    if (staged.entries.isEmpty) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('备份文件里没有可导入的数据')),
        );
      return;
    }
    if (!context.mounted) return;

    final ok = await _confirmImport(context, staged);
    if (ok != true) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('已取消导入')));
      return;
    }

    try {
      await service.applyImport(staged);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('还原完成，已生效')));
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('还原失败：$e')));
    }
  }

  /// 导出密码弹窗：返回 null=取消，空串=明文导出。
  Future<String?> _askExportPassword(BuildContext context) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导出备份'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '加密密码（可选）',
                hintText: '留空则导出明文备份',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '设置密码后，还原时需要输入同一密码。请牢记密码：'
              '密码丢失将无法恢复备份内容。',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('导出'),
          ),
        ],
      ),
    );
  }

  /// 导入密码弹窗（加密备份）：null=取消；[firstAttempt]=false 时提示密码错误。
  Future<String?> _askImportPassword(
    BuildContext context, {
    required bool firstAttempt,
  }) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(firstAttempt ? '备份已加密' : '密码错误或文件已损坏'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(firstAttempt ? '请输入导出时设置的密码：' : '请重新输入密码：'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              onSubmitted: (v) =>
                  Navigator.of(dialogContext).pop(controller.text),
              decoration: const InputDecoration(labelText: '密码'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 「将被覆盖的数据」确认框（中文 label 逐项列出）。
  Future<bool?> _confirmImport(BuildContext context, StagedImport staged) {
    final meta = <String>[
      if (staged.createdAt != null)
        '备份时间：${staged.createdAt!.toIso8601String().replaceAll(RegExp(r'\.\d+'), '')}',
      if (staged.appVersion.isNotEmpty) '导出版本：${staged.appVersion}',
      if (staged.encrypted) '已通过密码校验',
    ];
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导入备份？'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (meta.isNotEmpty) ...[
                Text(meta.join('\n'),
                    style: Theme.of(dialogContext).textTheme.bodySmall),
                const SizedBox(height: 8),
              ],
              const Text('以下本机数据将被覆盖：'),
              const SizedBox(height: 8),
              for (final e in staged.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('• '),
                      Expanded(child: Text(e.label)),
                      Text(
                        e.detail,
                        style: Theme.of(dialogContext).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                '其余数据保持不变。覆盖后不可撤销，请确认继续。',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认覆盖'),
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

/// 音质档位选择（Q1 锁态控件）：
///
/// - 64K / 132K 匿名可选；192K 需绑定；Hi-Res 需大会员（[AudioQuality.isUnlocked]）；
/// - 锁定档**灰显 + 锁标可见**，点击弹 SnackBar 引导（未绑定时 192K/Hi-Res
///   带「去绑定」直达绑定页）；
/// - 选档走 [PlayerService.setQuality]：立即重取址并续播（Q8a）。
class _QualityPicker extends StatelessWidget {
  const _QualityPicker({required this.player, required this.account});

  final PlayerService player;
  final BiliAccountService account;

  @override
  Widget build(BuildContext context) {
    final bound = account.bound;
    final isVip = account.isVip;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final q in AudioQuality.values)
          _QualityChip(
            label: q.label,
            selected: player.quality == q,
            locked: !q.isUnlocked(bound: bound, isVip: isVip),
            onTap: () => _pick(context, q, bound: bound, isVip: isVip),
          ),
      ],
    );
  }

  void _pick(
    BuildContext context,
    AudioQuality q, {
    required bool bound,
    required bool isVip,
  }) {
    if (!q.isUnlocked(bound: bound, isVip: isVip)) {
      final messenger = ScaffoldMessenger.of(context);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(_lockHint(q, bound: bound, isVip: isVip)),
            action: bound
                ? null
                : SnackBarAction(
                    label: '去绑定',
                    onPressed: () => context.push('/profile/bili-account'),
                  ),
          ),
        );
      return;
    }
    player.setQuality(q);
    // 首次选 Hi-Res：一次性流量提示（Q2a，提示过不再打扰）
    if (q == AudioQuality.qHiRes && !player.prefs.hiresHintShown) {
      player.prefs.saveHiresHintShown();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Hi-Res 无损音质流量约为 192K 的数倍，建议在 Wi-Fi 下收听。'),
            duration: Duration(seconds: 5),
          ),
        );
    }
  }
}

/// 单个音质档位：选中态 / 锁定态（灰显 + 锁标）均可点。
class _QualityChip extends StatelessWidget {
  const _QualityChip({
    required this.label,
    required this.selected,
    required this.locked,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final fg = switch ((selected, locked)) {
      (_, true) => scheme.onSurfaceVariant.withValues(alpha: 0.5),
      (true, false) => scheme.onPrimaryContainer,
      _ => scheme.onSurface,
    };
    final bg = switch ((selected, locked)) {
      (true, false) => scheme.primaryContainer,
      _ => scheme.surfaceContainerHighest.withValues(alpha: 0.5),
    };
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(tokens.radiusPill),
      child: InkWell(
        borderRadius: BorderRadius.circular(tokens.radiusPill),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: tokens.captionStyle.copyWith(
                  color: fg,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              if (locked) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.lock_outline_rounded,
                  size: 13,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 音质区动态说明行（随绑定/会员态变化）。
String _qualityHint(BiliAccountService account) {
  if (!account.bound) {
    return '当前可用 64K / 132K；绑定 B 站账号解锁 192K，开通大会员再解锁 Hi-Res。';
  }
  if (!account.isVip) {
    return '已解锁 192K；开通大会员可解锁 Hi-Res 无损音质。';
  }
  return '全部音质已解锁，可播放 Hi-Res 无损。';
}

/// 锁定档位点击引导文案。
String _lockHint(AudioQuality q, {required bool bound, required bool isVip}) {
  if (bound && !isVip && q == AudioQuality.qHiRes) {
    return 'Hi-Res 需要大会员解锁';
  }
  return '${q.label} 需要${q.needsVip ? '绑定 B 站账号并开通大会员' : '绑定 B 站账号'}解锁';
}

/// 账号绑定入口行：图标 + 标题/副标题 + 绑定状态，点击进入对应绑定页。
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
