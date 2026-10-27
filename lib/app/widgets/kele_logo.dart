import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// 品牌 Logo 徽标：应用内所有出现 logo 的位置统一用这一个组件，
/// 图片源为 `docs/images/icon.png` 的 256px 切图 `docs/images/icon_app.png`
/// （pubspec 已声明为资产，源图 / 切图规则见 AGENT.md「项目 Logo」与 tool/gen_icons.ps1）。
class KeleLogo extends StatelessWidget {
  const KeleLogo({super.key, this.size = 42, this.radius});

  /// 边长（正方形）。
  final double size;

  /// 圆角，默认跟随主题 radiusMd（logo 自带圆角，这里再裁一刀保证四角干净）。
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius ?? tokens.radiusMd),
      child: Image.asset(
        'docs/images/icon_app.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );
  }
}
