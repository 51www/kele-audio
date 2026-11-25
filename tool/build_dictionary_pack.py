#!/usr/bin/env python3
"""把 ECDICT 精简词库转换为 App 的精简词库 dict.json.zip。

用法：
  python3 tool/build_dictionary_pack.py \
      --csv /path/to/ecdict.mini.csv \
      --lemma /path/to/lemma.en.txt \
      --out ecdict-compact-v1.zip \
      --version ecdict-compact-v1

完整词库无需打包：App 直接下载 ECDICT 全量 CSV（ecdict.csv）。
数据来源：ECDICT（MIT）https://github.com/skywind3000/ECDICT
打包后请把 zip 作为 GitHub Release asset 发布，并把 sha256 写入发布说明。
"""

import argparse
import csv
import json
import zipfile
from pathlib import Path


def build(csv_path: Path, lemma_path: Path | None, out_path: Path, version: str) -> None:
    entries: dict[str, dict[str, str]] = {}
    with csv_path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            word = (row.get("word") or "").strip().lower()
            translation = (row.get("translation") or "").strip()
            if not word or not translation:
                continue
            entries[word] = {
                "word": word,
                "translation": translation,
                "pos": (row.get("pos") or "").strip(),
                "phonetic": (row.get("phonetic") or "").strip(),
            }

    aliases: dict[str, str] = {}
    if lemma_path and lemma_path.exists():
        with lemma_path.open("r", encoding="utf-8", errors="ignore") as handle:
            for line in handle:
                parts = line.strip().split()
                if len(parts) < 2:
                    continue
                variant, lemma = parts[0].strip().lower(), parts[1].strip().lower()
                if variant and lemma and lemma in entries:
                    aliases[variant] = lemma

    payload = {
        "version": version,
        "source": "ECDICT (MIT)",
        "entries": entries,
        "aliases": aliases,
    }
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("dict.json", raw)
    print(f"wrote {out_path} ({out_path.stat().st_size} bytes, {len(entries)} entries)")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", required=True, type=Path, help="ecdict.mini.csv 路径")
    parser.add_argument("--lemma", type=Path, help="lemma.en.txt 路径（可选）")
    parser.add_argument("--out", required=True, type=Path, help="输出 zip 路径")
    parser.add_argument("--version", default="ecdict-compact-v1")
    args = parser.parse_args()
    build(args.csv, args.lemma, args.out, args.version)


if __name__ == "__main__":
    main()
