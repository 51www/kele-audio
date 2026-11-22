"""统计 debug APK 的体积与 pdfrx 原生库占比（同 ABI 口径）。"""

import os
import zipfile

APK = r"e:/www/kele-audio/build/app/outputs/flutter-apk/app-debug.apk"


def main() -> None:
    total = os.path.getsize(APK)
    print(f"APK={APK}")
    print(f"文件体积={total}B ({total / 1024 / 1024:.2f}MB)")
    pdfium = 0
    gate = 0
    with zipfile.ZipFile(APK) as zf:
        infos = zf.infolist()
        print(f"条目数={len(infos)}")
        for info in infos:
            name = info.filename
            if "libpdfium" in name or "pdfrx_pdfium_gate" in name:
                ratio = info.compress_size / info.file_size if info.file_size else 0
                print(f"  {name}: 压缩={info.compress_size}B 原始={info.file_size}B "
                      f"压缩率={ratio:.3f}")
                if "libpdfium" in name:
                    pdfium += info.compress_size
                else:
                    gate += info.compress_size
    print(f"libpdfium 压缩合计={pdfium}B ({pdfium / 1024 / 1024:.2f}MB)")
    print(f"gate 压缩合计={gate}B ({gate / 1024:.1f}KB)")


if __name__ == "__main__":
    main()
