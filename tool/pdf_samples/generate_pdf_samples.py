"""生成 PDF 自造样本（M10.0）。

依赖：reportlab（本机通过 `python -m pip install --target <dir> reportlab` 安装，
脚本通过 PYTHONPATH 引入）。中文使用 reportlab 内置 CID 字体 STSong-Light，
PDF 内为预定义 CMap（UniGB-UCS2-H），不嵌入字体文件，样本体积小。

用法：
    set PYTHONPATH=C:/Users/EDY/.cache/pdfdeps
    python tool/pdf_samples/generate_pdf_samples.py

产物：docs/pdf-samples/*.pdf
"""

from pathlib import Path

from reportlab.lib.pagesizes import A4
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont
from reportlab.pdfgen import canvas
from reportlab.lib.utils import ImageReader

OUT_DIR = Path(__file__).resolve().parents[2] / "docs" / "pdf-samples"
FONT = "STSong-Light"
PAGE_W, PAGE_H = A4

BODY = (
    "城市的清晨从一层薄雾开始，街道两旁的梧桐树把光切成细碎的影子。"
    "早餐铺的蒸汽顺着屋檐往上爬，早点摊主把第一笼包子摆上案板，"
    "路过的人停下脚步，问一句今天是什么馅。"
)

LONG_PARAS = [
    "阅读是一场缓慢的旅行。文字在纸面上排队，句子之间留出呼吸的空隙，"
    "人们沿着段落向前走，偶尔回头，确认自己是否漏掉了某个细节。",
    "把一本书拆成章节，是为了让漫长的内容拥有可被记住的边界。"
    "章节标题像路标，读者在目录里挑选方向，然后重新回到正文。",
    "声音与文字的关系比想象中更紧密。朗读把标点变成停顿，"
    "把段落变成呼吸，把一本书的时间拉长成可以陪伴的节奏。",
    "排版决定了阅读的姿势。单栏适合连续的叙述，双栏更接近报纸的节奏，"
    "而带页眉页脚的版式则提醒读者，自己正处在某一本装订好的书里。",
    "技术文档常常夹着表格与图注，读者需要在这些碎片之间建立联系。"
    "如果抽取工具只按坐标排序，段落就可能被拆散，语义也随之漂移。",
]


def _wrap(text: str, width_chars: int) -> list[str]:
    return [text[i : i + width_chars] for i in range(0, len(text), width_chars)]


def _page_footer(c, page_no: int, total: int, label: str) -> None:
    c.setFont(FONT, 9)
    c.drawString(50, 30, label)
    c.drawRightString(PAGE_W - 50, 30, f"第 {page_no} / {total} 页")


def single_column(path: Path) -> None:
    c = canvas.Canvas(str(path), pagesize=A4)
    c.setTitle("单栏中文文字版")
    pages = 6
    for p in range(1, pages + 1):
        c.setFont(FONT, 16)
        c.drawString(50, PAGE_H - 70, f"第一章 城市清晨（{p}）")
        c.setFont(FONT, 11)
        y = PAGE_H - 100
        for para in [
            BODY,
            LONG_PARAS[(p + 1) % len(LONG_PARAS)],
            LONG_PARAS[p % len(LONG_PARAS)],
        ]:
            for line in _wrap(para, 34):
                c.drawString(50, y, line)
                y -= 18
            y -= 8
            if y < 80:
                break
        c.setFont(FONT, 9)
        c.drawRightString(PAGE_W - 50, 40, f"- {p} -")
        c.showPage()
    c.save()


def two_column(path: Path) -> None:
    c = canvas.Canvas(str(path), pagesize=A4)
    c.setTitle("双栏排版")
    pages = 4
    columns = [(50, 240), (310, 240)]
    for p in range(1, pages + 1):
        c.setFont(FONT, 14)
        c.drawString(50, PAGE_H - 60, f"第二版 双栏样本 · 第 {p} 页")
        c.setFont(FONT, 9.5)
        for col_index, (x, width_chars) in enumerate(columns):
            y = PAGE_H - 90
            for para in [
                f"左栏第 {p} 页" if col_index == 0 else f"右栏第 {p} 页",
                BODY,
                LONG_PARAS[(p + col_index) % len(LONG_PARAS)],
                LONG_PARAS[(p + col_index + 2) % len(LONG_PARAS)],
            ]:
                for line in _wrap(para, 18):
                    if y < 70:
                        break
                    c.drawString(x, y, line)
                    y -= 13
                y -= 5
        c.setFont(FONT, 9)
        c.drawRightString(PAGE_W - 50, 40, f"- {p} -")
        c.showPage()
    c.save()


def scanned_image_only(path: Path) -> None:
    from PIL import Image, ImageDraw, ImageFont

    font_path = Path(r"C:\Windows\Fonts\msyh.ttc")
    font = ImageFont.truetype(str(font_path), 30) if font_path.exists() else None
    c = canvas.Canvas(str(path), pagesize=A4)
    c.setTitle("扫描件（无文字层）")
    for p in range(1, 4):
        img = Image.new("RGB", (1240, 1754), "white")
        draw = ImageDraw.Draw(img)
        draw.rectangle([60, 60, 1180, 1694], outline="black", width=2)
        lines = [
            f"扫描样本 第 {p} 页",
            "本页正文以位图形式存在，",
            "不含可抽取的文字层。",
            "用于验证扫描件拦截。",
        ]
        y = 120
        for line in lines:
            if font:
                draw.text((120, y), line, fill="black", font=font)
            else:
                draw.text((120, y), line, fill="black")
            y += 60
        draw.line([100, 1500, 1100, 1500], fill="black", width=1)
        c.drawImage(ImageReader(img), 0, 0, width=PAGE_W, height=PAGE_H)
        c.showPage()
    c.save()


def header_footer_pagenum(path: Path) -> None:
    c = canvas.Canvas(str(path), pagesize=A4)
    c.setTitle("页眉页脚与页码")
    pages = 10
    for p in range(1, pages + 1):
        c.setFont(FONT, 8.5)
        c.drawString(50, PAGE_H - 35, "可乐听书 · 排版样本")
        c.drawRightString(PAGE_W - 50, PAGE_H - 35, "第一章 页眉示例")
        c.setFont(FONT, 11.5)
        y = PAGE_H - 75
        for para in [BODY, LONG_PARAS[p % len(LONG_PARAS)], BODY]:
            for line in _wrap(para, 34):
                if y < 100:
                    break
                c.drawString(50, y, line)
                y -= 19
            y -= 8
        _page_footer(c, p, pages, "页脚：可乐听书")
        c.showPage()
    c.save()


def long_document(path: Path) -> None:
    c = canvas.Canvas(str(path), pagesize=A4)
    c.setTitle("长文 220 页")
    total = 220
    for p in range(1, total + 1):
        c.setFont(FONT, 10)
        c.drawString(50, PAGE_H - 40, f"长文样本 · 第 {p} 页")
        y = PAGE_H - 70
        for i in range(6):
            para = LONG_PARAS[(p + i) % len(LONG_PARAS)]
            for line in _wrap(para, 35):
                if y < 60:
                    break
                c.drawString(50, y, line)
                y -= 16
            y -= 6
        c.setFont(FONT, 8.5)
        c.drawRightString(PAGE_W - 50, 35, f"- {p} -")
        c.showPage()
    c.save()


def main() -> None:
    pdfmetrics.registerFont(UnicodeCIDFont(FONT))
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    jobs = [
        ("01-single-column-zh.pdf", single_column),
        ("02-two-column-zh.pdf", two_column),
        ("03-scan-image-only.pdf", scanned_image_only),
        ("04-header-footer-pagenum.pdf", header_footer_pagenum),
        ("05-long-220p.pdf", long_document),
    ]
    for name, fn in jobs:
        target = OUT_DIR / name
        fn(target)
        print(f"{name}\t{target.stat().st_size / 1024:.1f} KB")


if __name__ == "__main__":
    main()
