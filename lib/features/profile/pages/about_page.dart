import 'package:flutter/material.dart';

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
        ],
      ),
    );
  }
}
