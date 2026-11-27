import 'package:flutter_test/flutter_test.dart';

import 'package:kele_audio/core/services/reader/epub_chapter_text.dart';
import 'package:kele_audio/core/services/reader/txt_to_epub.dart';

void main() {
  group('extractParagraphsFromXhtml（与 WebView 抽取同口径）', () {
    test('普通段落与标题', () {
      final html = '<body><h2>第一章</h2><p>第一段正文</p><p>第二段正文</p></body>';
      expect(
        EpubChapterText.extractParagraphsFromXhtml(html),
        ['第一章', '第一段正文', '第二段正文'],
      );
    });

    test('li 内嵌 p 只取最外层块，不重复朗读', () {
      final html = '<ul><li><p>列表项正文</p></li></ul>';
      expect(
        EpubChapterText.extractParagraphsFromXhtml(html),
        ['列表项正文'],
      );
    });

    test('blockquote 包多个 p 按 innerText 归一为一段', () {
      final html = '<blockquote><p>甲</p><p>乙</p></blockquote>';
      expect(
        EpubChapterText.extractParagraphsFromXhtml(html),
        ['甲 乙'],
      );
    });

    test('嵌套 li 折成一段，块边界计空格', () {
      final html = '<ul><li>甲<ul><li>乙</li></ul></li></ul>';
      expect(
        EpubChapterText.extractParagraphsFromXhtml(html),
        ['甲 乙'],
      );
    });

    test('<br/> 归一为空格', () {
      expect(
        EpubChapterText.extractParagraphsFromXhtml('<p>行一<br/>行二</p>'),
        ['行一 行二'],
      );
    });

    test('长度不足 2 的段落被过滤', () {
      expect(
        EpubChapterText.extractParagraphsFromXhtml(
          '<p>啊</p><p>好</p><p>正文内容</p>',
        ),
        ['正文内容'],
      );
    });

    test('script/style/nav 与注释不进入正文', () {
      final html = '<nav><p>目录项</p></nav>'
          '<script>var x = "<p>假段落</p>";</script>'
          '<!-- <p>注释段</p> -->'
          '<p>真段落</p>';
      expect(
        EpubChapterText.extractParagraphsFromXhtml(html),
        ['真段落'],
      );
    });

    test('实体与行内标签归一（行内标签不断词）', () {
      expect(
        EpubChapterText.extractParagraphsFromXhtml(
          '<p>他说：&ldquo;<em>你好</em>&mdash;&hellip;&rdquo; &#8220;数值&#8221;</p>',
        ),
        ['他说：“你好—…” “数值”'],
      );
    });

    test('空白折叠与 trim（同 textOf 归一）', () {
      expect(
        EpubChapterText.extractParagraphsFromXhtml(
          '<p>  多余   空白\n换行  </p>',
        ),
        ['多余 空白 换行'],
      );
    });
  });

  group('EpubChapterText 离线取段', () {
    test('按 spine 章序抽取 EpubBuilder 打包的章节，越界返回空', () async {
      final bytes = EpubBuilder.build(
        title: '测试书',
        chapters: const [
          EpubChapter(title: '第一章', html: '<p>第一段</p><p>第二段</p>'),
          EpubChapter(title: '第二章', html: '<p>第二章正文</p>'),
        ],
      );
      final source = EpubChapterText(loadBytes: (_) async => bytes);
      expect(await source.paragraphsOf('b1', 0), ['第一章', '第一段', '第二段']);
      expect(await source.paragraphsOf('b1', 1), ['第二章', '第二章正文']);
      expect(await source.paragraphsOf('b1', 2), isEmpty);
      expect(await source.paragraphsOf('b1', -1), isEmpty);
    });

    test('txt_to_html 的段内换行折为空格，空行分段', () async {
      final body = EpubBuilder.textToHtml('段一第一行\n段一第二行\n\n段二');
      final bytes = EpubBuilder.build(
        title: 'T',
        chapters: [EpubChapter(title: '第一章', html: body)],
      );
      final source = EpubChapterText(loadBytes: (_) async => bytes);
      expect(
        await source.paragraphsOf('b1', 0),
        ['第一章', '段一第一行 段一第二行', '段二'],
      );
    });

    test('换书后缓存不串书', () async {
      final bytesA = EpubBuilder.build(
        title: 'A',
        chapters: const [EpubChapter(title: 'A章', html: '<p>A正文</p>')],
      );
      final bytesB = EpubBuilder.build(
        title: 'B',
        chapters: const [EpubChapter(title: 'B章', html: '<p>B正文</p>')],
      );
      final source = EpubChapterText(
        loadBytes: (id) async => id == 'a' ? bytesA : bytesB,
      );
      expect(await source.paragraphsOf('a', 0), ['A章', 'A正文']);
      expect(await source.paragraphsOf('b', 0), ['B章', 'B正文']);
    });

    test('书籍文件缺失时抛异常（调用方按「取不到正文」暂停）', () async {
      final source = EpubChapterText(loadBytes: (_) async => null);
      await expectLater(
        source.paragraphsOf('b1', 0),
        throwsA(isA<StateError>()),
      );
    });
  });
}
