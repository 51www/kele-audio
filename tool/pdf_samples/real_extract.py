"""用 PDFium（pypdfium2，与 pdfrx 同引擎）抽取真实 PDF 样本的文字层。

用途：Windows 主机缺少 MSVC，无法在本机跑 pdfrx 原生资源构建，
因此用同一 PDFium 引擎做「真实文件」抽取质量标定；耗时/内存为
桌面代理数据，Android 真机待补验。

输出：tool/pdf_samples/real_extract.json（逐页文本 + 统计），供 Dart 侧
清洗/质量判定脚本消费。

依赖：`python -m pip install --target tool/.pylibs pypdfium2`（本地目录，不入库）。
"""

from __future__ import annotations

import json
import os
import sys
import time
import unicodedata

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".pylibs"))
import pypdfium2 as pdfium  # noqa: E402

SAMPLES = [
    r"c:\Users\EDY\.trae-cn\attachments\fad8a9cc-34c7-49fa-923f-f957ce361b1e_7d8df733-0b5f-43ed-9a0b-1a6af9404b95_2027年高考报名陆续启动 教育部发布防骗预警_新闻频道_央视网(cctv.com).pdf",
    r"c:\Users\EDY\.trae-cn\attachments\bfdfdb0f-bfec-4ac7-921c-c4db5451c8ea_03e21717-da38-4f28-8ec3-00506a017494_北京今天北风增大阵风5至6级 明起气温连降后天将有明显降水_新闻频道_央视网(cctv.com).pdf",
]

SUSPICIOUS_CONTROL = set(range(0x00, 0x20)) - {0x09, 0x0A, 0x0D}


def suspicious_ratio(text: str) -> float:
    total = len(text)
    if total == 0:
        return 0.0
    bad = 0
    for ch in text:
        code = ord(ch)
        if ch == "\ufffd" or code in SUSPICIOUS_CONTROL or 0xE000 <= code <= 0xF8FF:
            bad += 1
    return bad / total


def main() -> None:
    report = []
    for path in SAMPLES:
        entry = {"path": path, "fileName": os.path.basename(path)}
        if not os.path.exists(path):
            entry["error"] = "文件不存在"
            report.append(entry)
            continue
        entry["fileBytes"] = os.path.getsize(path)
        t0 = time.perf_counter()
        doc = pdfium.PdfDocument(path)
        open_ms = (time.perf_counter() - t0) * 1000
        pages = []
        extract_start = time.perf_counter()
        for index in range(len(doc)):
            t1 = time.perf_counter()
            textpage = doc[index].get_textpage()
            text = textpage.get_text_range()
            textpage.close()
            pages.append({"page": index + 1, "text": text,
                          "ms": round((time.perf_counter() - t1) * 1000, 2)})
        extract_ms = (time.perf_counter() - extract_start) * 1000
        doc.close()
        joined = "\n".join(p["text"] for p in pages)
        entry.update({
            "pageCount": len(pages),
            "openMs": round(open_ms, 2),
            "extractMs": round(extract_ms, 2),
            "totalChars": len(joined),
            "suspiciousRatio": round(suspicious_ratio(joined), 6),
            "perPage": [{"page": p["page"], "chars": len(p["text"]), "ms": p["ms"]}
                        for p in pages],
            "pages": pages,
        })
        report.append(entry)

    out = os.path.join(os.path.dirname(__file__), "real_extract.json")
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(report, fh, ensure_ascii=False, indent=1)

    for entry in report:
        if "error" in entry:
            print(entry["fileName"], entry["error"])
            continue
        print("=" * 70)
        print(entry["fileName"])
        print(f"  页数={entry['pageCount']} 文件={entry['fileBytes']}B "
              f"打开={entry['openMs']}ms 抽取={entry['extractMs']}ms "
              f"字符={entry['totalChars']} 异常占比={entry['suspiciousRatio']}")
        print("  每页字符/耗时：", ", ".join(
            f"p{p['page']}:{p['chars']}/{p['ms']}ms" for p in entry["perPage"]))


if __name__ == "__main__":
    main()
