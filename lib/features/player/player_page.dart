import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import '../../app/widgets/common.dart';

/// 播放页（PRD §5.4）—— M1 占位：控件结构齐、能力待 M2 接入。
class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key});

  void _todo(BuildContext context, String what) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$what 将在 M2 播放核心接入')));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('播放'),
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.spaceLg),
          child: Column(
            children: [
              SizedBox(height: tokens.spaceLg),
              // 封面（黑胶占位）
              Container(
                width: 230,
                height: 230,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      scheme.primary.withValues(alpha: 0.92),
                      scheme.secondary.withValues(alpha: 0.7),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.28),
                      blurRadius: 40,
                      offset: const Offset(0, 16),
                    ),
                  ],
                ),
                child: Center(
                  child: Container(
                    width: 74,
                    height: 74,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.surface.withValues(alpha: 0.92),
                    ),
                    child: Icon(
                      Icons.headphones_rounded,
                      color: scheme.primary,
                      size: 34,
                    ),
                  ),
                ),
              ),
              SizedBox(height: tokens.spaceLg),
              Text('未选择内容', style: tokens.titleStyle, textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text('在发现页点开专辑，选择章节即可开始收听', style: tokens.captionStyle),
              const SizedBox(height: 6),
              const StageTag('M2 播放核心', tone: StageTone.accent),
              SizedBox(height: tokens.spaceLg),

              // 进度条（占位）
              Slider(
                value: 0,
                onChanged: null,
                onChangeEnd: (_) => _todo(context, '拖拽 seek'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('00:00', style: tokens.numStyle),
                    Text('00:00', style: tokens.numStyle),
                  ],
                ),
              ),
              SizedBox(height: tokens.spaceMd),

              // 控制区
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: () => _todo(context, '上一章'),
                    icon: const Icon(Icons.skip_previous_rounded),
                    iconSize: 34,
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.all(0),
                      minimumSize: const Size(72, 72),
                      shape: const CircleBorder(),
                    ),
                    onPressed: () => _todo(context, '播放'),
                    child: const Icon(Icons.play_arrow_rounded, size: 42),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () => _todo(context, '下一章'),
                    icon: const Icon(Icons.skip_next_rounded),
                    iconSize: 34,
                  ),
                ],
              ),
              SizedBox(height: tokens.spaceMd),

              // 功能区
              Wrap(
                alignment: WrapAlignment.center,
                spacing: tokens.spaceSm,
                runSpacing: tokens.spaceSm,
                children: [
                  _FeatureChip(
                    icon: Icons.speed_rounded,
                    label: '倍速',
                    onTap: () => _todo(context, '倍速（0.5x~3.0x）'),
                  ),
                  _FeatureChip(
                    icon: Icons.bedtime_outlined,
                    label: '定时',
                    onTap: () => _todo(context, '定时关闭'),
                  ),
                  _FeatureChip(
                    icon: Icons.tune_rounded,
                    label: '音质',
                    onTap: () => _todo(context, '音质切换'),
                  ),
                  _FeatureChip(
                    icon: Icons.playlist_play_rounded,
                    label: '章节',
                    onTap: () => _todo(context, '章节抽屉'),
                  ),
                  _FeatureChip(
                    icon: Icons.menu_book_outlined,
                    label: '播放模式',
                    onTap: () => _todo(context, '播放模式'),
                  ),
                ],
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _todo(context, '加入书架（M4）'),
                  icon: const Icon(Icons.favorite_border_rounded, size: 18),
                  label: const Text('加入书架'),
                ),
              ),
              SizedBox(height: tokens.spaceMd),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeatureChip extends StatelessWidget {
  const _FeatureChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(tokens.radiusPill),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(tokens.radiusPill),
          border: Border.all(color: tokens.hairlineColor),
          color: scheme.surfaceContainer,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: scheme.primary),
            const SizedBox(width: 6),
            Text(
              label,
              style: tokens.captionStyle.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
