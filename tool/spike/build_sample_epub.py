# -*- coding: utf-8 -*-
"""M9.0 spike：生成样例 EPUB（3 章，每章足够长以便分页验证）。
产物：assets/reader/sample/sample.epub
"""
import os
import zipfile

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "reader", "sample", "sample.epub")

TITLE = "可乐听书·M9.0 技术验证样书"
AUTHOR = "kele-audio spike"

CHAPTERS = [
    ("第一章　山间来客", 40),
    ("第二章　夜航西飞", 40),
    ("第三章　晨光重现", 30),
]

SENTENCES = [
    "清晨的雾气从山谷里慢慢升起，像一层薄纱盖住了整片竹林。",
    "他背起行囊沿着石阶向上走，脚步声在空荡的山道间显得格外清晰。",
    "风从林梢掠过，带来远处溪水的凉意，也带来一声不知名的鸟鸣。",
    "路旁的野花开得正盛，黄的紫的挤在一起，仿佛谁不小心打翻了调色盘。",
    "老屋的门虚掩着，门轴发出悠长的吱呀声，像是在欢迎久别的故人。",
    "灶台上的铁锅咕嘟作响，米粥的香气一层层漫出窗棂，飘进院子里。",
    "午后的阳光斜斜地照进来，在木地板上铺出一片温暖的金色。",
    "她翻着那本旧书，纸页已经泛黄，字迹却依然清晰可辨。",
    "远处传来钟声，一声接一声，沉稳而悠远，敲进人的心里。",
    "夜色渐深，星子一颗颗亮起来，银河横过山脊，美得让人屏住呼吸。",
    "灯下的影子被拉得很长，笔尖划过纸面，沙沙声细密如春蚕食叶。",
    "他想起许多年前也是这样一个夜晚，也是这样一盏灯。",
    "山中无岁月，一晃眼，桃花开了又谢，溪水涨了又落。",
    "清晨推开窗，湿润的空气扑面而来，带着泥土与青草的芬芳。",
    "下山的路比上山更陡，他扶着栏杆一步一步慢慢往下走。",
]

XHTML_TMPL = """<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head>
  <meta charset="utf-8"/>
  <title>{title}</title>
  <link rel="stylesheet" type="text/css" href="style.css"/>
</head>
<body>
  <h1>{title}</h1>
{paragraphs}
</body>
</html>
"""


def make_chapter(idx, title, para_count):
    paras = []
    for i in range(para_count):
        s1 = SENTENCES[(i * 3 + idx) % len(SENTENCES)]
        s2 = SENTENCES[(i * 7 + idx + 5) % len(SENTENCES)]
        paras.append(f'  <p>第{idx + 1}章第{i + 1}段　{s1}{s2}山间的日子就这样一天天过去，日子平凡，却自有其滋味。</p>')
    return XHTML_TMPL.format(title=title, paragraphs="\n".join(paras))


def main():
    chapters = [make_chapter(i, t, n) for i, (t, n) in enumerate(CHAPTERS)]
    opf = f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">urn:uuid:kele-audio-m9-spike-sample</dc:identifier>
    <dc:title>{TITLE}</dc:title>
    <dc:creator>{AUTHOR}</dc:creator>
    <dc:language>zh-CN</dc:language>
    <meta property="dcterms:modified">2026-11-04T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="css" href="style.css" media-type="text/css"/>
    <item id="s0" href="chapter_0.xhtml" media-type="application/xhtml+xml"/>
    <item id="s1" href="chapter_1.xhtml" media-type="application/xhtml+xml"/>
    <item id="s2" href="chapter_2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="s0"/>
    <itemref idref="s1"/>
    <itemref idref="s2"/>
  </spine>
</package>
"""
    nav_items = "\n".join(
        f'      <li><a href="chapter_{i}.xhtml">{t}</a></li>' for i, (t, _) in enumerate(CHAPTERS)
    )
    nav = f"""<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><meta charset="utf-8"/><title>目录</title></head>
<body>
  <nav epub:type="toc" id="toc">
    <h1>目录</h1>
    <ol>
{nav_items}
    </ol>
  </nav>
</body>
</html>
"""
    container = """<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""
    css = """body { font-family: serif; line-height: 1.8; }
h1 { text-align: center; margin: 1.5em 0 1em; }
p { text-indent: 2em; margin: 0 0 0.6em; }
"""
    out = os.path.normpath(OUT)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        # mimetype 必须首个且不压缩
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", container)
        z.writestr("OEBPS/content.opf", opf)
        z.writestr("OEBPS/nav.xhtml", nav)
        z.writestr("OEBPS/style.css", css)
        for i, c in enumerate(chapters):
            z.writestr(f"OEBPS/chapter_{i}.xhtml", c)
    print(f"written: {out} ({os.path.getsize(out)} bytes)")


if __name__ == "__main__":
    main()
