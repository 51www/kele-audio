"""用 PDFium（pypdfium2）测自造 PDF 样本的文字层，作为 pdfrx 抽取质量的代理。

说明：pdfrx 底层就是 PDFium，文字层判定与取字结果一致；但本脚本在桌面端
运行，耗时/内存不等于 Android 真机（真机数据列「待真机补验」）。

用法：
    set PYTHONPATH=C:/Users/EDY/.cache/pdfdeps
    python tool/pdf_samples/bench_pypdfium2.py
"""

import re
import time
from pathlib import Path

import pypdfium2 as pdfium

SAMPLES = Path(__file__).resolve().parents[2] / "docs" / "pdf-samples"

PAGE_NO = re.compile(r"^[-—–]?\s*(第\s*)?\d+(\s*(页|/)\s*\d*)?\s*页?\s*[-—–]?$", re.U)


def suspicious_ratio(text: str) -> float:
    if not text:
        return 0.0
    bad = sum(
        1
        for ch in text
        if ch == "\ufffd" or ord(ch) < 0x20 and ch not in "\n\r\t" or 0xE000 <= ord(ch) <= 0xF8FF
    )
    return bad / len(text)


def cjk_ratio(text: str) -> float:
    if not text:
        return 0.0
    cjk = sum(1 for ch in text if 0x4E00 <= ord(ch) <= 0x9FFF)
    return cjk / len(text)


def main() -> None:
    for pdf_path in sorted(SAMPLES.glob("*.pdf")):
        size_kb = pdf_path.stat().st_size / 1024
        t0 = time.perf_counter()
        doc = pdfium.PdfDocument(str(pdf_path))
        open_ms = (time.perf_counter() - t0) * 1000
        n = len(doc)

        texts = []
        t1 = time.perf_counter()
        for i in range(n):
            page = doc[i]
            tp = page.get_textpage()
            texts.append(tp.get_text_range())
            tp.close()
            page.close()
        extract_ms = (time.perf_counter() - t1) * 1000
        doc.close()

        total = sum(len(t) for t in texts)
        non_empty = sum(1 for t in texts if t.strip())
        cjk = sum(sum(1 for ch in t if 0x4E00 <= ord(ch) <= 0x9FFF) for t in texts)
        bad = sum(sum(1 for ch in t if ch == "\ufffd" or 0xE000 <= ord(ch) <= 0xF8FF) for t in texts)
        print(
            f"{pdf_path.name}\t{size_kb:.1f}KB\tpages={n}\topen={open_ms:.0f}ms\t"
            f"extract={extract_ms:.0f}ms\tchars={total}\t"
            f"avg/page={total / n:.1f}\tnonEmpty={non_empty}\t"
            f"cjk={cjk / total * 100 if total else 0:.1f}%\tbad={bad / total * 100 if total else 0:.2f}%"
        )
        for i, t in enumerate(texts[:3], 1):
            if not t.strip():
                continue
            flat = t.replace("\n", " / ").strip()
            print(f"  p{i}: {flat[:200]}")

        # 页眉页脚/页码候选：统计每页首尾行是否为页码形态
        page_no_hits = 0
        for t in texts:
            lines = [ln.strip() for ln in t.splitlines() if ln.strip()]
            if lines and (PAGE_NO.match(lines[0]) or PAGE_NO.match(lines[-1])):
                page_no_hits += 1
        print(f"  pageNumberLikeLines={page_no_hits}/{n}")


if __name__ == "__main__":
    main()
