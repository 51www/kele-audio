import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/theme/app_tokens.dart';
import '../../app/theme/theme_controller.dart';
import '../../app/widgets/common.dart';
import '../../core/api/api_config.dart';
import '../../core/data/daos.dart';
import '../../core/data/local_database.dart';
import '../../core/services/listen_stats.dart';
import '../../core/services/player/player_service.dart';

/// 与 pubspec.yaml 的 version 保持一致（M5 设置页/关于页共用）。
const String appVersion = '1.0.0';

/// Tab 3 我的（PRD §5.6）。
///
/// M1 范围：页面骨架 + 二级页入口 + **全局主题切换**（浅/深/跟随系统）
/// + 工程自检；统计与设置项在 M5 完善。
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final theme = context.watch<ThemeController>();
    final config = context.read<ApiConfig>();
    final db = context.read<LocalDatabase>();
    // watch PlayerService：播放落进度（_saveNow→play_log）后摘要自动刷新
    context.watch<PlayerService>();
    final daos = context.read<Daos>();
    final stats = ListenStats.fromEntries(daos.playLogs.all());

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: EdgeInsets.only(bottom: tokens.spaceLg),
        children: [
          PageHeader(
            title: '我的',
            subtitle: '未登录 · 收藏与进度只存这台设备',
          ),

          // ── 收听摘要（M5：play_log 聚合；完整统计 M8） ──────────────
          Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.spaceMd),
            child: Row(
              children: [
                for (final (i, stat) in [
                  ('今日收听', ListenStats.formatDuration(stats.todaySec)),
                  ('本周收听', ListenStats.formatDuration(stats.weekSec)),
                  ('累计收听', ListenStats.formatDuration(stats.totalSec)),
                ].indexed) ...[
                  if (i > 0) SizedBox(width: tokens.spaceSm),
                  Expanded(
                    child: KeleCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 14,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            stat.$2,
                            style: tokens.titleStyle.copyWith(fontSize: 17),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Text(stat.$1, style: tokens.captionStyle),
                              const SizedBox(width: 6),
                              if (i == 2) const StageTag('M8 统计'),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          const SectionTitle('功能'),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.spaceMd),
            child: KeleCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _EntryTile(
                    icon: Icons.history_rounded,
                    label: '历史收听',
                    stage: '',
                    onTap: () => context.push('/profile/history'),
                  ),
                  _divider(tokens),
                  _EntryTile(
                    icon: Icons.download_for_offline_outlined,
                    label: '离线缓存',
                    stage: 'M8',
                    onTap: () => context.push('/profile/downloads'),
                  ),
                  _divider(tokens),
                  _EntryTile(
                    icon: Icons.bar_chart_rounded,
                    label: '听书统计',
                    stage: 'M8',
                    onTap: () => context.push('/profile/stats'),
                  ),
                  _divider(tokens),
                  _EntryTile(
                    icon: Icons.settings_outlined,
                    label: '设置',
                    stage: '',
                    onTap: () => context.push('/profile/settings'),
                  ),
                  _divider(tokens),
                  _EntryTile(
                    icon: Icons.info_outline_rounded,
                    label: '关于 / 版本',
                    stage: '',
                    onTap: () => context.push('/profile/about'),
                  ),
                ],
              ),
            ),
          ),

          // ── 工程自检（M1 准出：主题切换） ──────────────────────────
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spaceMd,
              tokens.spaceLg,
              tokens.spaceMd,
              0,
            ),
            child: KeleCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.tune_rounded, size: 18, color: scheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child:
                            Text('工程自检 · M1 骨架', style: tokens.sectionStyle),
                      ),
                      const StageTag('M1 准出', tone: StageTone.accent),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text('主题模式', style: tokens.captionStyle),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<ThemeMode>(
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
                      showSelectedIcon: false,
                      onSelectionChanged: (s) => theme.setMode(s.first),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _kvLine(tokens, '接口配置', config.describe()),
                  _kvLine(
                    tokens,
                    '数据库',
                    db.createResult?.describe ?? '未创建',
                  ),
                  _kvLine(tokens, '应用', 'com.kele.audio · v$appVersion'),
                  const SizedBox(height: 6),
                  Text(
                    '主题 token 化：页面不写死任何颜色，M6 儿童模式直接换一套 token。',
                    style: tokens.captionStyle,
                  ),
                ],
              ),
            ),
          ),

          // ── 免责声明（R3 必留） ────────────────────────────────────
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spaceMd,
              tokens.spaceLg,
              tokens.spaceMd,
              0,
            ),
            child: Text(
              '本应用为第三方个人开发的播放工具，与哔哩哔哩官方无任何关联。'
              '内容来自平台公开链接，版权归原作者所有；仅提供在线播放，'
              '不存储、不修改、不二次分发，仅供个人学习与收听使用。',
              style: tokens.captionStyle.copyWith(height: 1.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(AppTokens tokens) =>
      Divider(indent: 16, endIndent: 16, color: tokens.hairlineColor);

  Widget _kvLine(AppTokens tokens, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 62,
              child: Text(k, style: tokens.captionStyle),
            ),
            Expanded(
              child: Text(
                v,
                style: tokens.captionStyle.copyWith(
                  fontFamily: 'monospace',
                  fontSize: 11.5,
                  color: tokens.onHairline,
                ),
              ),
            ),
          ],
        ),
      );
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.stage = '',
  });

  final IconData icon;
  final String label;
  final String stage;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: tokens.bodyStyle)),
            if (stage.isNotEmpty) StageTag(stage),
            const SizedBox(width: 6),
            Icon(
              Icons.chevron_right_rounded,
              color: tokens.onHairline,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}
