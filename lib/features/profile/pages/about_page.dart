import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/widgets/common.dart';
import '../../../app/widgets/kele_logo.dart';
import '../profile_page.dart' show appVersion;
import '../../update/update_config.dart';
import '../../update/update_dialog.dart';
import '../../update/update_service.dart';

/// 关于 / 版本页（PRD §5.6.5）。
///
/// 必留：免责声明（R3）。开源声明与致谢区块已按用户要求移除（2026-10-26），勿恢复。
///
/// 检查更新（提示词 2）：Android 走完整闭环（检查 → 下载 → 安装），Web 仅保留静态
/// 仓库链接（不接逻辑）。平台判定使用 `!kIsWeb && TargetPlatform.android`，
/// 不用 `Platform.isAndroid`（Web 编译会炸）。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  late final bool _isAndroid;
  UpdateService? _service;
  String _realVersion = appVersion;

  @override
  void initState() {
    super.initState();
    _isAndroid =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    // 显示真实 package 版本，避免硬编码漂移误报（提示词 4）。
    PackageInfo.fromPlatform().then((PackageInfo info) {
      if (mounted) setState(() => _realVersion = info.version);
    });
    if (_isAndroid) {
      _service = UpdateService();
      _service!.init();
    }
  }

  String get _repoUrl => UpdateConfig.repoUrl;
  String get _feedbackUrl => '$_repoUrl/issues';

  Future<void> _onCheck() async {
    final UpdateService s = _service!;
    await s.check();
    if (!mounted) return;
    if (s.phase == UpdatePhase.available) {
      await showDialog<void>(
        context: context,
        builder: (_) => UpdateDialog(service: s),
      );
    } else if (s.phase == UpdatePhase.upToDate) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已是最新版本')),
      );
    }
  }

  @override
  void dispose() {
    _service?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = AppTokens.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('关于 / 版本')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          tokens.spaceMd,
          tokens.spaceSm,
          tokens.spaceMd,
          tokens.spaceLg,
        ),
        children: <Widget>[
          KeleCard(
            child: Row(
              children: <Widget>[
                const KeleLogo(size: 56),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('可乐听书', style: tokens.titleStyle),
                      const SizedBox(height: 4),
                      Text(
                        '版本 $_realVersion · com.kele.audio',
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
                const StageTag('正式版', tone: StageTone.accent),
              ],
            ),
          ),
          const SectionTitle('免责声明'),
          KeleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final (int i, String line) in _disclaimer.indexed) ...<Widget>[
                  if (i > 0) const SizedBox(height: 8),
                  Text(
                    '${i + 1}. $line',
                    style: tokens.bodyStyle.copyWith(height: 1.6),
                  ),
                ],
              ],
            ),
          ),
          const SectionTitle('版本与反馈'),
          KeleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '当前版本 $_realVersion。Android 端可点击下方「检查更新」获取新版安装包；'
                  '其他平台请前往仓库 Releases 页面。',
                  style: tokens.bodyStyle.copyWith(height: 1.6),
                ),
                const SizedBox(height: 12),
                if (_isAndroid && _service != null)
                  _CheckUpdateRow(service: _service!, onCheck: _onCheck)
                else
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
                  _isAndroid
                      ? '更新与反馈走仓库链接；检查更新永不强制，可随时取消。'
                      : '更新与反馈走仓库链接，点击可复制。',
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

/// 检查更新行（仅 Android）：三态（检查中 / 已是最新 / 发现新版 / 失败可重试）。
class _CheckUpdateRow extends StatelessWidget {
  const _CheckUpdateRow({
    required this.service,
    required this.onCheck,
  });

  final UpdateService service;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = AppTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: service,
      builder: (BuildContext context, _) {
        final UpdatePhase phase = service.phase;
        final bool checking = phase == UpdatePhase.checking;

        Widget trailing;
        if (checking) {
          trailing = const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          );
        } else if (phase == UpdatePhase.error) {
          trailing = Icon(Icons.refresh_rounded, size: 18, color: scheme.error);
        } else {
          trailing = Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: tokens.onHairline,
          );
        }

        return InkWell(
          onTap: checking ? null : onCheck,
          child: Row(
            children: <Widget>[
              Icon(Icons.system_update_alt_rounded,
                  size: 18, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      phase == UpdatePhase.error
                          ? '检查更新（失败，点击重试）'
                          : '检查更新',
                      style: tokens.bodyStyle,
                    ),
                    if (phase == UpdatePhase.error &&
                        service.errorMessage != null) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        service.errorMessage!,
                        style: tokens.captionStyle
                            .copyWith(color: scheme.error),
                      ),
                    ] else if (phase == UpdatePhase.available &&
                        service.release != null) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        '发现新版本 v${service.release!.tagName}',
                        style: tokens.captionStyle
                            .copyWith(color: scheme.primary),
                      ),
                    ],
                  ],
                ),
              ),
              trailing,
            ],
          ),
        );
      },
    );
  }
}

const List<String> _disclaimer = <String>[
  '本应用为第三方个人开发的播放工具，与哔哩哔哩官方无任何关联，亦未获得其授权或背书。',
  '应用内所有音频、封面与文字均来自平台公开链接，版权归原作者及相关权利人所有。',
  '本应用不存储、不修改、不二次分发任何内容，仅提供在线播放与本地记录。',
  '内容仅供个人学习与收听使用，请支持正版；如涉及侵权请联系即处理。',
  '使用本应用产生的后果由使用者自行承担。',
];

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
    final AppTokens tokens = AppTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Icon(icon, size: 18, color: scheme.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
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
