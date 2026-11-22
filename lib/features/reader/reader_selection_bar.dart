import 'package:flutter/material.dart';

/// 选中正文后浮出的操作条：划线 / 查词 / 复制 / 关闭。
class ReaderSelectionBar extends StatelessWidget {
  const ReaderSelectionBar({
    super.key,
    required this.onHighlight,
    required this.onLookup,
    required this.onCopy,
    required this.onDismiss,
  });

  final VoidCallback onHighlight;
  final VoidCallback onLookup;
  final VoidCallback onCopy;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.inverseSurface,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Action(
            icon: Icons.edit_outlined,
            label: '划线',
            color: scheme.onInverseSurface,
            onTap: onHighlight,
          ),
          _Action(
            icon: Icons.translate_outlined,
            label: '查词',
            color: scheme.onInverseSurface,
            onTap: onLookup,
          ),
          _Action(
            icon: Icons.copy_all_outlined,
            label: '复制',
            color: scheme.onInverseSurface,
            onTap: onCopy,
          ),
          _Action(
            icon: Icons.close_rounded,
            label: '关闭',
            color: scheme.onInverseSurface,
            onTap: onDismiss,
          ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 19, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(fontSize: 10, color: color),
            ),
          ],
        ),
      ),
    );
  }
}
