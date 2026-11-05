import '../../core/domain/reader_book.dart';

/// 书架分栏（M10 追加需求）：本地导入的书与在线收藏分开。
enum ShelfSection { local, favorite }

extension ShelfSectionX on ShelfSection {
  String get label => switch (this) {
    ShelfSection.local => '本地',
    ShelfSection.favorite => '收藏',
  };
}

/// 归类规则（唯一入口，测试与此保持同步）：
/// - localTxt / localEpub / localPdf → 本地；
/// - webArticle → null：数据保留，但不在书架任何分栏展示（收藏栏只放专辑）。
ShelfSection? shelfSectionOf(ReaderBookSource source) =>
    source.isLocalImport ? ShelfSection.local : null;

/// 书架网格列数（按可用逻辑宽度自适应，封顶 3 列）。
///
/// 断点依据：720px 窄屏约 240dp → 2 列，避免单卡过窄；
/// 常见竖屏手机 360dp / 横屏与平板 ≥600dp → 3 列。
/// 用户要求一行 2~3 个，因此平板也不再扩到 4 列。
int shelfGridColumns(double width) => width < 340 ? 2 : 3;

/// 分栏空态文案（纯值对象，便于单测）。
class ShelfEmptySpec {
  const ShelfEmptySpec({
    required this.title,
    required this.message,
    required this.actionLabel,
  });

  final String title;
  final String message;
  final String actionLabel;
}

ShelfEmptySpec shelfEmptySpecOf(ShelfSection section) => switch (section) {
  ShelfSection.local => const ShelfEmptySpec(
    title: '还没有本地书',
    message: '导入 TXT / EPUB / PDF 后就能在这里阅读与听书。\n'
        '扫描件 PDF（无文字层）暂不支持。',
    actionLabel: '导入本地文件',
  ),
  ShelfSection.favorite => const ShelfEmptySpec(
    title: '还没有收藏的专辑',
    message: '在专辑详情页点「加入书架」，\n收藏的专辑会收在这里。',
    actionLabel: '去发现页逛逛',
  ),
};
