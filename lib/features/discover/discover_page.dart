import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/di.dart';
import '../../app/theme/app_tokens.dart';
import '../../app/theme/theme_controller.dart';
import '../../app/widgets/common.dart';
import '../../core/api/content_config.dart';
import '../../core/services/settings_store.dart';
import 'category_feed.dart';

/// Tab 1 发现页（PRD §5.1，M3 接入真实内容源；M6 接入儿童模式联动）。
///
/// 结构：搜索入口（同类产品惯例：内容流顶部一条搜索胶囊）→ 横向分类 Tab
/// → [IndexedStack] 信息流。原顶部品牌栏已按需求隐藏（品牌信息收敛到「我的-关于」）。
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

  /// 当前模式下的分类：儿童模式 → 儿童白名单五类，否则成人 7 类。
  /// 再按「高级设置」显隐过滤（「推荐」类固定显示，见 [SettingsStore.isCategoryVisible]）。
  List<CategoryConfig> _categoriesOf(BuildContext context) {
    final services = context.read<AppServices>();
    final kids = context.read<ThemeController>().children;
    final settings = context.read<SettingsStore>();
    final all = kids
        ? services.childrenContent.childrenCategories
        : services.content.adultCategories;
    return all.where((c) => settings.isCategoryVisible(c.id)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final kids = context.watch<ThemeController>().children;
    final settings = context.watch<SettingsStore>();
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

    // 显隐变化兜底：当前分类被隐藏 → 切回第一个可见分类（保活的 feed 不清）。
    if (categories.isNotEmpty && !categories.any((c) => c.id == _categoryId)) {
      _categoryId = categories.first.id;
      if (!_visited.any((c) => c.id == _categoryId)) {
        _visited.add(categories.first);
      }
    }

    if (categories.isEmpty) {
      return const Center(child: Text('内容配置为空，请重启应用重试'));
    }

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          if (!kids) _buildSearchEntry(context, tokens, scheme),
          if (!kids && settings.featuredVisible && activeConfig.featured.isNotEmpty)
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

  /// 搜索入口（同类产品惯例：内容流顶部一条不可输入的搜索胶囊，
  /// 点击整条跳搜索页）。儿童模式不展示（白名单内不需要搜索）。
  Widget _buildSearchEntry(
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
      child: Material(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(tokens.radiusPill),
        child: InkWell(
          borderRadius: BorderRadius.circular(tokens.radiusPill),
          onTap: () => context.push('/search'),
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(tokens.radiusPill),
              border: Border.all(color: tokens.hairlineColor),
            ),
            child: Row(
              children: [
                Icon(Icons.search_rounded, size: 22, color: tokens.onHairline),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '搜索有声书、相声、播单…',
                    style: tokens.captionStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
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
