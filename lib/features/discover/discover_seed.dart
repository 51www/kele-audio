/// 发现页种子数据（M1 占位）。
///
/// M3 接入真实内容源后，这里只保留「分类定义」（对应 PRD §7.2 的查询配置），
/// 卡片数据由 `core/api` 搜索/合集聚合产生。
library;

class DiscoverCategory {
  const DiscoverCategory({required this.id, required this.label, required this.keyword});

  /// 分类 id（= `category_id`，专辑缓存表用它归类）
  final String id;
  final String label;

  /// M3 的内容源查询关键词（PRD §7.2 `source=search`）
  final String keyword;
}

/// 成人模式首批 5 个分类（PRD §5.1）。
const List<DiscoverCategory> kDiscoverCategories = [
  DiscoverCategory(id: 'rec', label: '推荐', keyword: '有声书'),
  DiscoverCategory(id: 'xiaoshuo', label: '有声书', keyword: '有声小说'),
  DiscoverCategory(id: 'xiangsheng', label: '相声曲艺', keyword: '相声'),
  DiscoverCategory(id: 'jiangshu', label: '讲书', keyword: '讲书'),
  DiscoverCategory(id: 'music', label: '音乐', keyword: '纯音乐'),
];

/// 儿童模式五类分类（M6 接白名单源，这里先声明结构）
const List<DiscoverCategory> kChildrenCategories = [
  DiscoverCategory(id: 'picture_book', label: '绘本', keyword: '绘本'),
  DiscoverCategory(id: 'nursery', label: '儿歌', keyword: '儿歌'),
  DiscoverCategory(id: 'fairy_tale', label: '童话故事', keyword: '童话故事'),
  DiscoverCategory(id: 'bedtime', label: '睡前故事', keyword: '睡前故事'),
  DiscoverCategory(id: 'science', label: '科普', keyword: '科普'),
];

class SeedAlbum {
  const SeedAlbum({
    required this.id,
    required this.title,
    required this.upName,
    required this.chapters,
    required this.durationLabel,
    required this.playCount,
    required this.categories,
  });

  final String id;
  final String title;
  final String upName;
  final int chapters;
  final String durationLabel;
  final String playCount;
  final List<String> categories;

  bool inCategory(String id) =>
      categories.contains('rec') || categories.contains(id);
}

/// 占位内容：结构与真实数据一致（封面/标题/UP 主/章节数/时长/播放量），
/// 供 M1 验证双列卡片流与滚动状态；M3 整体替换为接口数据。
const List<SeedAlbum> kSeedAlbums = [
  SeedAlbum(
    id: 'm1-001',
    title: '活着 · 余华原著有声剧全集',
    upName: '声工厂夜读',
    chapters: 86,
    durationLabel: '26 小时',
    playCount: '128.4 万',
    categories: ['rec', 'xiaoshuo'],
  ),
  SeedAlbum(
    id: 'm1-002',
    title: '三体 · 广播剧第一季',
    upName: '729 声工场',
    chapters: 30,
    durationLabel: '18 小时',
    playCount: '96.1 万',
    categories: ['rec', 'xiaoshuo'],
  ),
  SeedAlbum(
    id: 'm1-003',
    title: '单田芳评书合集 · 白眉大侠',
    upName: '评书频道',
    chapters: 120,
    durationLabel: '42 小时',
    playCount: '310.2 万',
    categories: ['rec', 'xiangsheng'],
  ),
  SeedAlbum(
    id: 'm1-004',
    title: '郭德纲相声精选 2024',
    upName: '德云社精选',
    chapters: 64,
    durationLabel: '21 小时',
    playCount: '255.7 万',
    categories: ['xiangsheng'],
  ),
  SeedAlbum(
    id: 'm1-005',
    title: '明朝那些事儿 · 讲书版',
    upName: '老梁开讲',
    chapters: 45,
    durationLabel: '15 小时',
    playCount: '72.8 万',
    categories: ['rec', 'jiangshu'],
  ),
  SeedAlbum(
    id: 'm1-006',
    title: '夜色钢琴曲 · 睡前轻音乐',
    upName: '音乐疗愈室',
    chapters: 24,
    durationLabel: '9 小时',
    playCount: '41.3 万',
    categories: ['music'],
  ),
  SeedAlbum(
    id: 'm1-007',
    title: '平凡的世界 · 全三部',
    upName: '紫襟演播',
    chapters: 168,
    durationLabel: '58 小时',
    playCount: '188.9 万',
    categories: ['rec', 'xiaoshuo'],
  ),
  SeedAlbum(
    id: 'm1-008',
    title: '盗墓笔记 · 有声小说全集',
    upName: '周建龙',
    chapters: 96,
    durationLabel: '33 小时',
    playCount: '402.5 万',
    categories: ['xiaoshuo'],
  ),
  SeedAlbum(
    id: 'm1-009',
    title: '刘兰芳演播 · 岳飞传',
    upName: '曲艺大观',
    chapters: 110,
    durationLabel: '39 小时',
    playCount: '87.6 万',
    categories: ['xiangsheng'],
  ),
  SeedAlbum(
    id: 'm1-010',
    title: '通俗经济学 · 十本书讲透',
    upName: '知识传声筒',
    chapters: 40,
    durationLabel: '12 小时',
    playCount: '33.2 万',
    categories: ['rec', 'jiangshu'],
  ),
  SeedAlbum(
    id: 'm1-011',
    title: '大提琴夜曲 · 深眠系列',
    upName: '白噪音研究所',
    chapters: 18,
    durationLabel: '7 小时',
    playCount: '19.4 万',
    categories: ['music'],
  ),
  SeedAlbum(
    id: 'm1-012',
    title: '聊斋志异 · 全本演播',
    upName: '古韵声声',
    chapters: 72,
    durationLabel: '24 小时',
    playCount: '54.1 万',
    categories: ['rec', 'xiaoshuo'],
  ),
  SeedAlbum(
    id: 'm1-013',
    title: '哈利波特 · 中文有声书',
    upName: '魔法声研社',
    chapters: 60,
    durationLabel: '28 小时',
    playCount: '143.0 万',
    categories: ['xiaoshuo'],
  ),
  SeedAlbum(
    id: 'm1-014',
    title: '马三立相声典藏',
    upName: '相声大世界',
    chapters: 38,
    durationLabel: '11 小时',
    playCount: '66.7 万',
    categories: ['xiangsheng'],
  ),
  SeedAlbum(
    id: 'm1-015',
    title: '国学经典 · 论语与孟子讲读',
    upName: '书院电台',
    chapters: 52,
    durationLabel: '16 小时',
    playCount: '27.5 万',
    categories: ['rec', 'jiangshu'],
  ),
  SeedAlbum(
    id: 'm1-016',
    title: '晨间古典 · 巴洛克精选',
    upName: '音乐疗愈室',
    chapters: 20,
    durationLabel: '8 小时',
    playCount: '22.8 万',
    categories: ['music'],
  ),
  SeedAlbum(
    id: 'm1-017',
    title: '鬼吹灯之精绝古城 · 有声剧',
    upName: '声工厂夜读',
    chapters: 88,
    durationLabel: '30 小时',
    playCount: '271.3 万',
    categories: ['rec', 'xiaoshuo'],
  ),
  SeedAlbum(
    id: 'm1-018',
    title: '曾国藩家书 · 讲书版',
    upName: '知行读书会',
    chapters: 36,
    durationLabel: '10 小时',
    playCount: '18.6 万',
    categories: ['jiangshu'],
  ),
  SeedAlbum(
    id: 'm1-019',
    title: '侯宝林相声选',
    upName: '相声大世界',
    chapters: 30,
    durationLabel: '9 小时',
    playCount: '45.2 万',
    categories: ['xiangsheng'],
  ),
  SeedAlbum(
    id: 'm1-020',
    title: '星际宇宙 · 科普有声读物',
    upName: '知识传声筒',
    chapters: 44,
    durationLabel: '13 小时',
    playCount: '31.9 万',
    categories: ['rec', 'jiangshu'],
  ),
  SeedAlbum(
    id: 'm1-021',
    title: '红楼梦 · 全本朗读',
    upName: '古韵声声',
    chapters: 120,
    durationLabel: '46 小时',
    playCount: '93.4 万',
    categories: ['xiaoshuo'],
  ),
  SeedAlbum(
    id: 'm1-022',
    title: '雨夜吉他 · 助眠纯音',
    upName: '白噪音研究所',
    chapters: 16,
    durationLabel: '6 小时',
    playCount: '15.7 万',
    categories: ['music'],
  ),
  SeedAlbum(
    id: 'm1-023',
    title: '世界名著速读 · 五十本',
    upName: '知行读书会',
    chapters: 50,
    durationLabel: '14 小时',
    playCount: '39.8 万',
    categories: ['rec', 'jiangshu'],
  ),
  SeedAlbum(
    id: 'm1-024',
    title: '武侠群英传 · 评书连播',
    upName: '评书频道',
    chapters: 96,
    durationLabel: '35 小时',
    playCount: '61.0 万',
    categories: ['xiangsheng'],
  ),
];

List<SeedAlbum> seedFor(String categoryId) {
  if (categoryId == 'rec') return kSeedAlbums;
  return kSeedAlbums.where((a) => a.categories.contains(categoryId)).toList();
}
