"""
生成 Android 自适应图标前景层（ic_launcher_foreground.png）。

问题背景：
  旧版前景是全出血 logo（铺满整张 108dp 画布），启动器掩膜会裁掉四周约 20%，
  导致 logo 在桌面看起来被「放大 / 裁切」。

修复方式（标准自适应图标做法）：
  - 背景（values/ic_launcher_background.xml 的 #F98E5F）保留为图标底色；
  - 前景只放 logo 图形本身，居中放进画布正中央约 66% 的安全区，四周留透明边距，
    掩膜只裁掉透明边，logo 以预期大小居中显示，不再放大。

用法：
  python tool/gen_adaptive_foreground.py
依赖：Pillow
"""
import os
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "docs/images/icon.png")
RES = os.path.join(ROOT, "android/app/src/main/res")

# 各密度下自适应图标画布尺寸（108dp 基准）
DENSITIES = {
    "mipmap-mdpi": 108,
    "mipmap-hdpi": 162,
    "mipmap-xhdpi": 216,
    "mipmap-xxhdpi": 324,
    "mipmap-xxxhdpi": 432,
}

SAFE_ZONE_RATIO = 0.66  # 标志置于画布中央 66% 安全区（Material 规范保证不被掩膜裁切）


def tight_crop(im: Image.Image) -> Image.Image:
    """按不透明区域(α>10)裁出 logo 紧致包围盒。"""
    im = im.convert("RGBA")
    alpha = im.split()[-1]
    bbox = alpha.point(lambda a: 255 if a > 10 else 0).getbbox()
    if bbox is None:
        raise ValueError("源图没有任何不透明像素")
    return im.crop(bbox)


def main():
    src = Image.open(SRC).convert("RGBA")
    glyph = tight_crop(src)
    gw, gh = glyph.size

    for folder, canvas in DENSITIES.items():
        # 目标：logo 最长边 = 安全区尺寸；保持比例，偶数对齐
        target = int(round(canvas * SAFE_ZONE_RATIO))
        scale = target / max(gw, gh)
        new_w, new_h = max(1, int(round(gw * scale))), max(1, int(round(gh * scale)))
        # 偶数对齐，避免某些启动器渲染错位
        new_w += new_w % 2
        new_h += new_h % 2
        resized = glyph.resize((new_w, new_h), Image.LANCZOS)

        out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
        paste_x = (canvas - new_w) // 2
        paste_y = (canvas - new_h) // 2
        out.paste(resized, (paste_x, paste_y), resized)

        dst = os.path.join(RES, folder, "ic_launcher_foreground.png")
        out.save(dst, "PNG")
        print(f"write {dst}  canvas={canvas} glyph={new_w}x{new_h}")


if __name__ == "__main__":
    main()
