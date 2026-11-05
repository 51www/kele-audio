import 'package:flutter_test/flutter_test.dart';

import 'package:kele_audio/core/domain/reader_book.dart';
import 'package:kele_audio/core/services/reader/pdf_page_map.dart';
import 'package:kele_audio/core/services/reader/pdf_quality.dart';
import 'package:kele_audio/core/services/reader/pdf_text_normalizer.dart';
import 'package:kele_audio/core/services/reader/txt_to_epub.dart';
import 'package:kele_audio/features/shelf/shelf_tab.dart';

ReaderBook _book({
  required ReaderBookSource source,
  PdfReadQuality? quality,
  int pdfPageCount = 0,
}) => ReaderBook(
  id: 'b1',
  title: '测试书',
  source: source,
  fileName: 'book.epub',
  chapterCount: 3,
  pdfPageCount: pdfPageCount,
  pdfQuality: quality,
  addedAt: DateTime(2026),
);

void main() {
  group('ReaderBook.fromStorage（M10）', () {
    test('localPdf 能正确反序列化，不会回退成 TXT', () {
      final json = _book(
        source: ReaderBookSource.localPdf,
        quality: PdfReadQuality.mixed,
        pdfPageCount: 120,
      ).toJson();
      final restored = ReaderBook.fromJson(json);
      expect(restored.source, ReaderBookSource.localPdf);
      expect(restored.pdfPageCount, 120);
      expect(restored.pdfQuality, PdfReadQuality.mixed);
    });

    test('未知来源仍回退 TXT（老数据兼容）', () {
      expect(ReaderBookSourceX.fromStorage('unknown'), ReaderBookSource.localTxt);
      expect(ReaderBookSourceX.fromStorage(null), ReaderBookSource.localTxt);
    });

    test('不可靠质量关闭听书入口', () {
      final book = _book(
        source: ReaderBookSource.localPdf,
        quality: PdfReadQuality.unreliable,
      );
      expect(book.ttsAllowed, isFalse);
      expect(book.ttsDisabledReason, isNotNull);
    });

    test('混合版仍允许听书（只朗读有文字的页）', () {
      final book = _book(
        source: ReaderBookSource.localPdf,
        quality: PdfReadQuality.mixed,
      );
      expect(book.ttsAllowed, isTrue);
    });
  });

  group('PDF 文字层质量判定', () {
    test('整本无字 → 扫描件', () {
      final inspection = PdfQualityAnalyzer.analyze(
        fileName: 'scan.pdf',
        path: '/tmp/scan.pdf',
        fileBytes: 1024,
        pageCount: 3,
        pages: const [
          PdfExtractedPage(pageNumber: 1, text: ''),
          PdfExtractedPage(pageNumber: 2, text: ' '),
          PdfExtractedPage(pageNumber: 3, text: '\n'),
        ],
      );
      expect(inspection.scanned, isTrue);
      expect(inspection.quality, PdfReadQuality.unreliable);
    });

    test('部分页面无字 → 混合版', () {
      final inspection = PdfQualityAnalyzer.analyze(
        fileName: 'mixed.pdf',
        path: '/tmp/mixed.pdf',
        fileBytes: 1024,
        pageCount: 5,
        pages: const [
          PdfExtractedPage(pageNumber: 1, text: '第一章 正文内容足够长，用于判定。'),
          PdfExtractedPage(pageNumber: 2, text: ''),
          PdfExtractedPage(pageNumber: 3, text: '第三章 正文内容足够长，用于判定。'),
          PdfExtractedPage(pageNumber: 4, text: ''),
          PdfExtractedPage(pageNumber: 5, text: '第五章 正文内容足够长，用于判定。'),
        ],
      );
      expect(inspection.scanned, isFalse);
      expect(inspection.quality, PdfReadQuality.mixed);
      expect(inspection.emptyPageCount, 2);
    });

    test('异常字符过多 → 不可靠', () {
      final inspection = PdfQualityAnalyzer.analyze(
        fileName: 'bad.pdf',
        path: '/tmp/bad.pdf',
        fileBytes: 1024,
        pageCount: 1,
        pages: const [
          PdfExtractedPage(
            pageNumber: 1,
            text: '正文\u0001\u0002\u0003\u0004\u0005\u0006\u0007',
          ),
        ],
      );
      expect(inspection.quality, PdfReadQuality.unreliable);
      expect(inspection.suspiciousRatio, greaterThan(0));
    });

    test('正常文字层 → good', () {
      final inspection = PdfQualityAnalyzer.analyze(
        fileName: 'ok.pdf',
        path: '/tmp/ok.pdf',
        fileBytes: 1024,
        pageCount: 2,
        pages: const [
          PdfExtractedPage(pageNumber: 1, text: '第一页的正文包含足够的字符，内容正常。'),
          PdfExtractedPage(pageNumber: 2, text: '第二页的正文包含足够的字符，内容正常。'),
        ],
      );
      expect(inspection.quality, PdfReadQuality.good);
      expect(inspection.scanned, isFalse);
    });
  });

  group('PDF 文本清洗与段落化', () {
    final pages = [
      '可乐听书 · 排版样本\n第一章 标题\n'
          '阅读是一场缓慢的旅行。文字在纸面上排队，句子之间留出呼吸的空隙。\n'
          '人们沿着段落向前走，偶尔回头。\n'
          '页脚：可乐听书\n第 1 / 4 页',
      '可乐听书 · 排版样本\n第二章 标题\n'
          '把一本书拆成章节，是为了让漫长的内容拥有边界。\n'
          '标题像路标，读者在目录里挑选方向。\n'
          '页脚：可乐听书\n第 2 / 4 页',
      '可乐听书 · 排版样本\n第三章 标题\n'
          '声音与文字的关系比想象中更紧密。\n'
          '朗读把标点变成停顿。\n'
          '页脚：可乐听书\n第 3 / 4 页',
    ];

    test('重复页眉页脚与页码被剔除', () {
      final paragraphs = PdfTextNormalizer.paragraphsFromPages(pages);
      final joined = paragraphs.join('\n');
      expect(joined, isNot(contains('排版样本')));
      expect(joined, isNot(contains('页脚：可乐听书')));
      expect(joined, isNot(contains('第 1 / 4 页')));
    });

    test('同一段落的换行被合并，且不产生空段', () {
      final paragraphs = PdfTextNormalizer.paragraphsFromPages(pages);
      expect(paragraphs, isNotEmpty);
      expect(paragraphs.every((p) => p.trim().isNotEmpty), isTrue);
      expect(paragraphs.every((p) => !p.contains('\n')), isTrue);
      expect(joinedContains(paragraphs, '人们沿着段落向前走'), isTrue);
    });

    test('跨页未结束的句子会与下一页合并', () {
      final paragraphs = PdfTextNormalizer.paragraphsFromPages([
        '这是一个很长很长的段落，它在第一页没有说完，',
        '所以第二页接着继续写下去，直到这句话结束。',
      ]);
      expect(paragraphs.length, 1);
      expect(paragraphs.single, contains('接着继续写下去'));
    });

    test('逐段生成 <p>，避免整章被 TTS 当一段', () {
      final paragraphs = PdfTextNormalizer.paragraphsFromPages(pages);
      final html = EpubBuilder.textToHtml(paragraphs.join('\n\n'));
      expect('<p>'.allMatches(html).length, paragraphs.length);
    });
  });

  group('PDF 页码映射', () {
    test('220 页按 20 页一章分组', () {
      final map = PdfPageMap.grouped(pageCount: 220, pagesPerChapter: 20);
      expect(map.chapters.length, 11);
      expect(map.chapterForPage(1), 0);
      expect(map.chapterForPage(20), 0);
      expect(map.chapterForPage(21), 1);
      expect(map.chapterForPage(220), 10);
      expect(map.labelForChapter(1), '第 21–40 页');
    });

    test('JSON 往返与越界夹取', () {
      final map = PdfPageMap.grouped(pageCount: 35, pagesPerChapter: 20);
      final restored = PdfPageMap.tryDecode(map.encode());
      expect(restored, isNotNull);
      expect(restored!.pageCount, 35);
      expect(restored.chapterForPage(0), 0);
      expect(restored.chapterForPage(99), 1);
    });
  });

  group('书架网格', () {
    test('窄屏 2 列，常规与平板 3 列（封顶 3）', () {
      expect(shelfGridColumns(240), 2);
      expect(shelfGridColumns(339), 2);
      expect(shelfGridColumns(360), 3);
      expect(shelfGridColumns(800), 3);
      expect(shelfGridColumns(1200), 3);
    });

    test('卡片进度紧凑且百分比优先', () {
      final pdf = _book(
        source: ReaderBookSource.localPdf,
        pdfPageCount: 220,
      ).copyWith(
        chapterCount: 10,
        lastReadAt: DateTime(2026),
        lastChapterIndex: 4,
        lastFraction: 0.5,
      );
      expect(pdf.progressBrief, '45% · 220 页');

      final txt = _book(source: ReaderBookSource.localTxt).copyWith(
        lastReadAt: DateTime(2026),
        lastFraction: 0.5,
      );
      expect(txt.progressBrief, '17% · 1/3 章');

      final unread = _book(source: ReaderBookSource.localEpub);
      expect(unread.progressBrief, '未开始阅读');
    });
  });

  group('书架分栏归类', () {
    test('本地来源进「本地」，网页文章不进任何分栏', () {
      expect(
        shelfSectionOf(ReaderBookSource.localTxt),
        ShelfSection.local,
      );
      expect(
        shelfSectionOf(ReaderBookSource.localEpub),
        ShelfSection.local,
      );
      expect(
        shelfSectionOf(ReaderBookSource.localPdf),
        ShelfSection.local,
      );
      expect(shelfSectionOf(ReaderBookSource.webArticle), isNull);
    });

    test('两个分栏的空态文案不同且行动导向明确', () {
      final local = shelfEmptySpecOf(ShelfSection.local);
      final favorite = shelfEmptySpecOf(ShelfSection.favorite);
      expect(local.title, isNot(favorite.title));
      expect(local.actionLabel, '导入本地文件');
      expect(favorite.actionLabel, '去发现页逛逛');
      expect(favorite.message, contains('收藏'));
      expect(favorite.message, contains('专辑'));
      expect(favorite.message, isNot(contains('网页')));
    });
  });
}

bool joinedContains(List<String> paragraphs, String needle) =>
    paragraphs.any((p) => p.contains(needle));
