import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/di.dart';
import '../../app/theme/app_tokens.dart';
import '../../app/theme/theme_controller.dart';
import '../../app/widgets/common.dart';
import '../../core/api/content_config.dart';
import 'category_feed.dart';

/// Tab 1 发现页（PRD §5.1，M3 接入真实内容源；M6 接入儿童模式联动）。
///
/// 结构：顶部栏（含儿童模式开关）→ 横向分类 Tab → [IndexedStack] 信息流。
/// 每个分类一个 [CategoryFeed]：**访问过才创建，创建后保留滚动位置与页码**；
/// 成人分类来自 `assets/api/content_config.json`，儿童五类来自
/// `assets/api/children_config.json`（白名单，PRD §7.3）。
class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  /// 已访问过的分类（保持 feed 实例与滚动位置）。
  final List<CategoryConfig> _visited = [];
  String _categoryId = '';
  bool _kidsAtBuild = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_visited.isEmpty) {
      final cats = _categoriesOf(context);
      if (cats.isNotEmpty) {
        _categoryId = cats.first.id;
        _visited.add(cats.first);
      }
    }
  }

  /// 当前模式下的分类：儿童模式 → 儿童白名单五类，否则成人 5 类。
  List<CategoryConfig> _categoriesOf(BuildContext context) {
    final services = context.read<AppServices>();
    final kids = context.read<ThemeController>().children;
    return kids
        ? services.childrenContent.childrenCategories
        : services.content.adultCategories;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final kids = context.watch<ThemeController>().children;
    final services = context.read<AppServices>();
    final activeConfig = kids ? services.childrenContent : services.content;
    final cacheTtl = Duration(minutes: activeConfig.cacheTtlMinutes);
    final categories = _categoriesOf(context);

    // 模式切换（M6）：分类集合整体替换，feed 实例与滚动位置重建，
    // 避免成人/儿童 feed 串内容。
    if (kids != _kidsAtBuild) {
      _kidsAtBuild = kids;
      _visited
        ..clear()
        ..addAll(categories);
      _categoryId = categories.isNotEmpty ? categories.first.id : '';
    }

    if (categories.isEmpty) {
      return const Center(child: Text('内容配置为空，请重启应用重试'));
    }

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          _buildHeader(context, tokens, scheme),
          if (!kids && activeConfig.featured.isNotEmpty)
            _buildFeatured(context, tokens, scheme, activeConfig.featured),
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
    final kids = context.watch<ThemeController>().children;
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
                color: tokens.onAccent,
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
                Text(
                  kids ? '儿童模式已开启 · 只看白名单内容' : '免登录 · 无广告 · 专注收听',
                  style: tokens.captionStyle,
                ),
              ],
            ),
          ),
          // 搜索（M8）：成人模式显示，儿童模式收起（白名单内不需要搜索）
          if (!kids)
            IconButton(
              tooltip: '搜索',
              onPressed: () => context.push('/search'),
              icon: const Icon(Icons.search_rounded),
            ),
          // 儿童模式开关（PRD §5.5）：开启直接切，关闭走二次确认防误触
          IconButton(
            tooltip: kids ? '退出儿童模式' : '进入儿童模式',
            style: IconButton.styleFrom(
              backgroundColor:
                  kids ? scheme.primary.withValues(alpha: 0.14) : null,
            ),
            onPressed: () => _toggleKids(context, kids),
            icon: Icon(
              kids ? Icons.child_care : Icons.child_care_outlined,
              color: kids ? scheme.primary : null,
            ),
          ),
        ],
      ),
    );
  }

  /// Banner + 编辑精选（M8 / PRD §5.1）：内容配置下发的专题关键词，
  /// 点卡跳搜索页出结果（`/search?q=...`）。主题渐变 + emoji，不写死颜色。
  Widget _buildFeatured(
    BuildContext context,
    AppTokens tokens,
    ColorScheme scheme,
    List<FeaturedTopic> topics,
  ) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spaceMd,
        tokens.spaceMd,
        tokens.spaceMd,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 96,
            child: PageView.builder(
              controller: PageController(viewportFraction: 0.92),
              itemCount: topics.length,
              itemBuilder: (context, i) {
                final t = topics[i];
                return Padding(
                  padding: EdgeInsets.only(
                    right: i == topics.length - 1 ? 0 : tokens.spaceSm,
                  ),
                  child: KeleCard(
                    onTap: () =>
                        context.push('/search?q=${Uri.encodeComponent(t.keyword)}'),
                    padding: EdgeInsets.symmetric(
                      horizontal: tokens.spaceMd,
                      vertical: tokens.spaceSm,
                    ),
                    child: Row(
                      children: [
                        Text(t.emoji, style: const TextStyle(fontSize: 30)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                '编辑精选 · ${t.title}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: tokens.sectionStyle,
                              ),
                              if (t.subtitle.isNotEmpty)
                                Text(
                                  '${t.subtitle} · ${t.keyword}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: tokens.captionStyle,
                                ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.chevron_right_rounded,
                          color: tokens.onHairline,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

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
