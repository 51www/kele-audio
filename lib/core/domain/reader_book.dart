import 'dart:math' as math;

/// 本地书来源（M9.1）：
/// - [localTxt]：本地 TXT，导入时切章并转成内部 EPUB；
/// - [localEpub]：本地 EPUB，校验后原样落盘；
/// - [localPdf]：本地 PDF，抽取文字层后转成内部 EPUB；
/// - [localMobi]：本地 MOBI / AZW，解出文本层后转成内部 EPUB；
/// - [webArticle]：网页文章，抓取正文后生成 EPUB 快照。
enum ReaderBookSource {
  localTxt,
  localEpub,
  localPdf,
  localMobi,
  webArticle,
}

extension ReaderBookSourceX on ReaderBookSource {
  /// 存储用字符串（JSON 落盘）。
  String get storageValue => name;

  /// 书架来源角标文案。
  String get label => switch (this) {
    ReaderBookSource.localTxt => 'TXT',
    ReaderBookSource.localEpub => 'EPUB',
    ReaderBookSource.localPdf => 'PDF',
    ReaderBookSource.localMobi => 'MOBI',
    ReaderBookSource.webArticle => '网页',
  };

  /// 是否为本机导入的书（书架「本地」分栏）。
  ///
  /// 网页文章同样是用户主动导入、抓取后以 EPUB 快照落盘，
  /// 导入成功后必须在「本地」分栏可见，否则会出现「提示成功却找不到」。
  bool get isLocalImport =>
      this == ReaderBookSource.localTxt ||
      this == ReaderBookSource.localEpub ||
      this == ReaderBookSource.localPdf ||
      this == ReaderBookSource.localMobi ||
      this == ReaderBookSource.webArticle;

  static ReaderBookSource fromStorage(String? value) {
    for (final source in ReaderBookSource.values) {
      if (source.storageValue == value) return source;
    }
    return ReaderBookSource.localTxt;
  }
}

/// PDF 文字层质量（M10）。
///
/// - [good]：文字层完整，可重排阅读与朗读；
/// - [mixed]：部分页无可抽取文字（扫描页混排），缺字页面在阅读页留白，
///   其余页面可正常阅读/朗读；
/// - [unreliable]：抽取结果疑似乱码或顺序不可靠（B 级），仍可阅读，
///   但关闭朗读书入口，避免 TTS 念出乱码。
enum PdfReadQuality { good, mixed, unreliable }

extension PdfReadQualityX on PdfReadQuality {
  String get storageValue => name;

  String get label => switch (this) {
    PdfReadQuality.good => '文字层完整',
    PdfReadQuality.mixed => '部分页面无文字层',
    PdfReadQuality.unreliable => '文字抽取不可靠',
  };

  static PdfReadQuality? fromStorage(String? value) {
    for (final quality in PdfReadQuality.values) {
      if (quality.storageValue == value) return quality;
    }
    return null;
  }
}

/// 本地书领域模型（docs/reader-design.md §2.1）。
///
/// 书籍文件统一落盘为 EPUB（`books/{id}/book.epub`），各类来源因此共用
/// 同一条阅读/朗读管线；本模型只保存元数据与进度冗余字段。
class ReaderBook {
  const ReaderBook({
    required this.id,
    required this.title,
    this.author = '',
    required this.source,
    this.originUrl,
    required this.fileName,
    required this.chapterCount,
    this.coverPath,
    required this.addedAt,
    this.lastReadAt,
    this.lastChapterIndex = 0,
    this.lastFraction = 0,
    this.lastTtsParaIndex,
    this.pdfPageCount = 0,
    this.pdfQuality,
    this.removed = false,
  });

  /// 书籍 id：时间戳 + 随机后缀，同时作为文件目录名。
  final String id;
  final String title;
  final String author;
  final ReaderBookSource source;

  /// 网页书专有：用于「重新抓取」。
  final String? originUrl;

  /// 落盘 EPUB 文件名（不含目录）。
  final String fileName;

  /// 章节数（TXT 为切章数；EPUB 从 OPF spine 读取；网页为切章数）。
  final int chapterCount;

  /// 封面路径（M9.1 暂未提取，留空走字母占位）。
  final String? coverPath;

  final DateTime addedAt;

  /// 最后一次阅读时间（null = 尚未阅读）。
  final DateTime? lastReadAt;

  /// 最后阅读章节索引（0 基）。
  final int lastChapterIndex;

  /// 章内进度（0~1）。
  final double lastFraction;

  /// 听书断点（章内段落序号），M9.3 使用。
  final int? lastTtsParaIndex;

  /// PDF 总页数（非 PDF 为 0）。
  final int pdfPageCount;

  /// PDF 文字层质量（非 PDF 为 null）。
  final PdfReadQuality? pdfQuality;

  /// 是否允许听书；B 级（[PdfReadQuality.unreliable]）PDF 关闭 TTS。
  bool get ttsAllowed =>
      source != ReaderBookSource.localPdf ||
      pdfQuality != PdfReadQuality.unreliable;

  /// 听书被关闭时的提示文案。
  String? get ttsDisabledReason => ttsAllowed
      ? null
      : '该 PDF 的文字抽取不可靠（疑似乱码或阅读顺序混乱），已关闭朗读。';

  /// 软删除标记（书架左滑/多选删除后置 true，可撤销）。
  final bool removed;

  /// 总体进度（0~1）。
  double get overallProgress {
    if (chapterCount <= 0) return 0;
    final current = (lastChapterIndex + lastFraction).clamp(
      0.0,
      chapterCount.toDouble(),
    );
    return (current / chapterCount).clamp(0.0, 1.0);
  }

  /// 进度百分比（0~100）。
  int get progressPercent => (overallProgress * 100).round();

  /// 书架行上的进度文案。
  String get progressText {
    if (lastReadAt == null) return '未开始阅读';
    if (source == ReaderBookSource.localPdf && pdfPageCount > 0) {
      return '已读 $progressPercent% · 共 $pdfPageCount 页';
    }
    if (chapterCount <= 0) return '已打开';
    final current = math.min(lastChapterIndex + 1, chapterCount);
    return '已读 $current/$chapterCount 章 · $progressPercent%';
  }

  /// 书架网格卡片上的紧凑进度（单行可放下，百分比优先）。
  String get progressBrief {
    if (lastReadAt == null) return '未开始阅读';
    if (source == ReaderBookSource.localPdf && pdfPageCount > 0) {
      return '$progressPercent% · $pdfPageCount 页';
    }
    if (chapterCount <= 0) return '$progressPercent%';
    final current = math.min(lastChapterIndex + 1, chapterCount);
    return '$progressPercent% · $current/$chapterCount 章';
  }

  ReaderBook copyWith({
    String? id,
    String? title,
    String? author,
    ReaderBookSource? source,
    String? originUrl,
    String? fileName,
    int? chapterCount,
    String? coverPath,
    DateTime? addedAt,
    DateTime? lastReadAt,
    int? lastChapterIndex,
    double? lastFraction,
    int? lastTtsParaIndex,
    int? pdfPageCount,
    PdfReadQuality? pdfQuality,
    bool? removed,
  }) {
    return ReaderBook(
      id: id ?? this.id,
      title: title ?? this.title,
      author: author ?? this.author,
      source: source ?? this.source,
      originUrl: originUrl ?? this.originUrl,
      fileName: fileName ?? this.fileName,
      chapterCount: chapterCount ?? this.chapterCount,
      coverPath: coverPath ?? this.coverPath,
      addedAt: addedAt ?? this.addedAt,
      lastReadAt: lastReadAt ?? this.lastReadAt,
      lastChapterIndex: lastChapterIndex ?? this.lastChapterIndex,
      lastFraction: lastFraction ?? this.lastFraction,
      lastTtsParaIndex: lastTtsParaIndex ?? this.lastTtsParaIndex,
      pdfPageCount: pdfPageCount ?? this.pdfPageCount,
      pdfQuality: pdfQuality ?? this.pdfQuality,
      removed: removed ?? this.removed,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'source': source.storageValue,
    'originUrl': originUrl,
    'fileName': fileName,
    'chapterCount': chapterCount,
    'coverPath': coverPath,
    'addedAt': addedAt.toIso8601String(),
    'lastReadAt': lastReadAt?.toIso8601String(),
    'lastChapterIndex': lastChapterIndex,
    'lastFraction': lastFraction,
    'lastTtsParaIndex': lastTtsParaIndex,
    'pdfPageCount': pdfPageCount,
    'pdfQuality': pdfQuality?.storageValue,
    'removed': removed,
  };

  factory ReaderBook.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(Object? value) =>
        value is String && value.isNotEmpty ? DateTime.tryParse(value) : null;

    return ReaderBook(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '未命名',
      author: json['author']?.toString() ?? '',
      source: ReaderBookSourceX.fromStorage(json['source']?.toString()),
      originUrl: json['originUrl']?.toString(),
      fileName: json['fileName']?.toString() ?? 'book.epub',
      chapterCount: (json['chapterCount'] as num?)?.toInt() ?? 0,
      coverPath: json['coverPath']?.toString(),
      addedAt: parseDate(json['addedAt']) ?? DateTime.now(),
      lastReadAt: parseDate(json['lastReadAt']),
      lastChapterIndex: (json['lastChapterIndex'] as num?)?.toInt() ?? 0,
      lastFraction: (json['lastFraction'] as num?)?.toDouble() ?? 0,
      lastTtsParaIndex: (json['lastTtsParaIndex'] as num?)?.toInt(),
      pdfPageCount: (json['pdfPageCount'] as num?)?.toInt() ?? 0,
      pdfQuality: PdfReadQualityX.fromStorage(json['pdfQuality']?.toString()),
      removed: json['removed'] == true,
    );
  }
}
