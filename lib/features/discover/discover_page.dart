import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme/app_tokens.dart';
import '../../core/api/content_config.dart';
import 'category_feed.dart';

/// Tab 1 发现页（PRD §5.1，M3 接入真实内容源）。
///
/// 结构：顶部栏 → 横向分类 Tab（内容配置下发）→ [IndexedStack] 信息流。
/// 每个分类一个 [CategoryFeed]：**访问过才创建，创建后保留滚动位置与页码**；
/// 分类数据来自 `assets/api/content_config.json`（内置）+ 远端覆盖（R1 热修复）。
class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  /// 已访问过的分类（保持 feed 实例与滚动位置）。
  final List<CategoryConfig> _visited = [];
  String _categoryId = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_visited.isEmpty) {
      final cats = context.read<ContentConfig>().adultCategories;
      if (cats.isNotEmpty) {
        _categoryId = cats.first.id;
        _visited.add(cats.first);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final config = context.read<ContentConfig>();
    final cacheTtl = Duration(minutes: config.cacheTtlMinutes);
    final categories = config.adultCategories;

    if (categories.isEmpty) {
      return const Center(child: Text('内容配置为空，请重启应用重试'));
    }

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          _buildHeader(context, tokens, scheme),
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spaceMd,
              tokens.spaceMd,
              tokens.spaceMd,
              tokens.spaceSm,
            ),
            child: Row(
              children: [
                Text('按类型找内容', style: tokens.sectionStyle),
              ],
            ),
          ),
          _buildChips(tokens, scheme, categories),
          SizedBox(height: tokens.spaceSm),
          Expanded(
            child: IndexedStack(
              index: _visited.indexWhere((c) => c.id == _categoryId),
              children: [
                for (final cat in _visited)
                  CategoryFeed(key: ValueKey(cat.id), category: cat, ttl: cacheTtl),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    AppTokens tokens,
    ColorScheme scheme,
  ) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spaceMd,
        tokens.spaceMd,
        tokens.spaceMd,
        0,
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              gradient: tokens.accentGradient,
              borderRadius: BorderRadius.circular(tokens.radiusMd),
            ),
            alignment: Alignment.center,
            child: Text(
              '可',
              style: TextStyle(
                color: scheme.onPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('可乐听书', style: tokens.titleStyle),
                Text('免登录 · 无广告 · 专注收听', style: tokens.captionStyle),
              ],
            ),
          ),
          IconButton(
            tooltip: '儿童模式 · M6 接入',
            onPressed: () => ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(const SnackBar(
                content: Text('儿童模式将在 M6 接入（主题皮肤 + 白名单内容）'),
              )),
            icon: const Icon(Icons.child_care_outlined),
          ),
        ],
      ),
    );
  }

  Widget _buildChips(
    AppTokens tokens,
    ColorScheme scheme,
    List<CategoryConfig> categories,
  ) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: tokens.spaceMd),
        itemCount: categories.length,
        separatorBuilder: (_, _) => SizedBox(width: tokens.spaceSm),
        itemBuilder: (context, i) {
          final cat = categories[i];
          final selected = cat.id == _categoryId;
          return InkWell(
            borderRadius: BorderRadius.circular(tokens.radiusPill),
            onTap: () {
              if (cat.id == _categoryId) return;
              setState(() {
                _categoryId = cat.id;
                if (!_visited.any((c) => c.id == cat.id)) _visited.add(cat);
              });
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: selected ? scheme.primary : scheme.surfaceContainer,
                borderRadius: BorderRadius.circular(tokens.radiusPill),
                border: Border.all(
                  color: selected ? scheme.primary : tokens.hairlineColor,
                ),
              ),
              child: Text(
                cat.name,
                style: tokens.bodyStyle.copyWith(
                  fontWeight: FontWeight.w700,
                  color: selected ? scheme.onPrimary : scheme.onSurface,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
