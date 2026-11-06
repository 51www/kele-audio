import '../../core/domain/reader_book.dart';

/// 书架条目来源（合并为单一列表后只用于归类，不再驱动分栏）。
enum ShelfOrigin { localBook }

extension ShelfOriginX on ShelfOrigin {
  /// 封面角标：本地书用格式，收藏专辑用来源文字。
  String get label => switch (this) {
    ShelfOrigin.localBook => '本地',
  };
}

/// 来源归类唯一入口：
/// - localTxt / localEpub / localPdf / webArticle → 本地书（网页文章抓取后
///   同样以 EPUB 快照落盘，维持导入后即可见）；
/// - 其余 → null（当前没有不进入书架的本地来源）。
ShelfOrigin? shelfOriginOf(ReaderBookSource source) =>
    source.isLocalImport ? ShelfOrigin.localBook : null;

/// 书架网格列数：参考图为三列等宽栅格，固定 3 列。
int shelfGridColumns(double width) => 3;

/// 合并后的书架空态文案（纯值对象，便于单测）。
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

const ShelfEmptySpec shelfEmptySpec = ShelfEmptySpec(
  title: '书架还是空的',
  message: '导入 TXT / EPUB / PDF，或在专辑详情页点「加入书架」，\n内容会一起排在这里。扫描件 PDF（无文字层）暂不支持。',
  actionLabel: '导入本地文件',
);
