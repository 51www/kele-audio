import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/widgets/common.dart';
import '../profile_page.dart' show appVersion;

/// 关于 / 版本页（PRD §5.6.5）。
///
/// 必留：免责声明（R3）+ MIT 开源声明与对 abts 的致谢（AGENT.md 规则 4）。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static const _disclaimer = [
    '本应用为第三方个人开发的播放工具，与哔哩哔哩官方无任何关联，亦未获得其授权或背书。',
    '应用内所有音频、封面与文字均来自平台公开链接，版权归原作者及相关权利人所有。',
    '本应用不存储、不修改、不二次分发任何内容，仅提供在线播放与本地记录。',
    '内容仅供个人学习与收听使用，请支持正版；如涉及侵权请联系即处理。',
    '使用本应用产生的后果由使用者自行承担。',
  ];

  static const _packages = [
    ('dio', 'HTTP 客户端'),
    ('provider', '状态管理'),
    ('go_router', '声明式路由'),
    ('shared_preferences', '本地键值存储'),
    ('media_kit', '播放内核（M2 接入）'),
    ('audio_service', '后台与锁屏控制（M2 接入）'),
    ('crypto', 'WBI 签名 md5'),
  ];

  /// MVP 静态文案 + 更新链接（PRD §5.6.5：检查更新可为静态文本）。
  /// 正式发布后可换成 GitHub Releases 比对（abts 同款 `app_update` 思路）。
  static const _releaseNotes =
      '当前版本 $appVersion 为 MVP 预览版，无自动更新通道。'
      '新版本发布后请到项目仓库 Releases 页面获取。';

  static const _repoUrl = 'https://github.com/kele-audio/kele-audio';
  static const _feedbackUrl = '$_repoUrl/issues';

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('关于 / 版本')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          tokens.spaceMd,
          tokens.spaceSm,
          tokens.spaceMd,
          tokens.spaceLg,
        ),
        children: [
          KeleCard(
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    gradient: tokens.accentGradient,
                    borderRadius: BorderRadius.circular(tokens.radiusMd),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '可',
                    style: TextStyle(
                      color: scheme.onPrimary,
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('可乐听书', style: tokens.titleStyle),
                      const SizedBox(height: 4),
                      Text(
                        '版本 $appVersion · com.kele.audio',
                        style: tokens.captionStyle,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '基于 B 站公开内容的听书播放器 · 仅 Android',
                        style: tokens.captionStyle,
                      ),
                    ],
                  ),
                ),
                const StageTag('MVP 前', tone: StageTone.accent),
              ],
            ),
          ),

          const SectionTitle('免责声明'),
          KeleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (i, line) in _disclaimer.indexed) ...[
                  if (i > 0) const SizedBox(height: 8),
                  Text(
                    '${i + 1}. $line',
                    style: tokens.bodyStyle.copyWith(height: 1.6),
                  ),
                ],
              ],
            ),
          ),

          const SectionTitle('开源声明与致谢'),
          KeleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '本项目采用 MIT 协议。逻辑与数据层大量参考了 abts（阿B听书），'
                  '在此致谢其作者与贡献者（MIT License）。',
                  style: tokens.bodyStyle.copyWith(height: 1.6),
                ),
                const SizedBox(height: 12),
                Text('主要依赖', style: tokens.captionStyle),
                const SizedBox(height: 6),
                for (final (name, desc) in _packages)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Icon(Icons.code_rounded,
                            size: 14, color: scheme.primary),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 140,
                          child: Text(
                            name,
                            style: tokens.captionStyle.copyWith(
                              fontFamily: 'monospace',
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                        Expanded(child: Text(desc, style: tokens.captionStyle)),
                      ],
                    ),
                  ),
                const SizedBox(height: 10),
                Text(
                  'MIT License · Copyright (c) kele-audio contributors',
                  style: tokens.captionStyle.copyWith(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),

          const SectionTitle('版本与反馈'),
          KeleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_releaseNotes, style: tokens.bodyStyle.copyWith(height: 1.6)),
                const SizedBox(height: 12),
                _LinkRow(
                  icon: Icons.system_update_alt_rounded,
                  label: '检查更新 / 发布页',
                  value: _repoUrl,
                  onCopy: () => _copyLink(context, _repoUrl),
                ),
                const Divider(height: 20),
                _LinkRow(
                  icon: Icons.feedback_outlined,
                  label: '意见反馈（GitHub Issues）',
                  value: _feedbackUrl,
                  onCopy: () => _copyLink(context, _feedbackUrl),
                ),
                const SizedBox(height: 10),
                Text(
                  'MVP 阶段更新与反馈走仓库链接，点击可复制。',
                  style: tokens.captionStyle,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copyLink(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: url));
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('链接已复制')));
  }
}

/// 可复制的链接行：图标 + 标题 + 链接 + 复制按钮。
class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onCopy,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 18, color: scheme.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: tokens.bodyStyle),
              const SizedBox(height: 2),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tokens.captionStyle.copyWith(
                  fontFamily: 'monospace',
                  fontSize: 11.5,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: '复制链接',
          onPressed: onCopy,
          icon: const Icon(Icons.copy_rounded, size: 18),
        ),
      ],
    );
  }
}
