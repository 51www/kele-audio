# -*- coding: utf-8 -*-
"""把新图标接入 Flutter Android 自适应图标：替换 mipmap-* 的
   ic_launcher.png / ic_launcher_foreground.png，并把背景色改为 #3A2B23。"""
import os
from PIL import Image, ImageDraw

BG = (58, 43, 35, 255)      # #3A2B23
WHITE = (255, 255, 255, 255)
DARK = (46, 42, 75, 255)
ORANGE = (245, 138, 91, 255)
YELLOW = (242, 178, 75, 255)
SS = 4                      # 超采样抗锯齿

DENS = {
    "mipmap-mdpi": 48, "mipmap-hdpi": 72, "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144, "mipmap-xxxhdpi": 192,
}
RES = r"E:\www\kele-audio\android\app\src\main\res"
FG_SCALE = 0.66             # 自适应安全区占比（xml 注释要求的 66%）


def render(S, scale_fg, with_bg):
    big = S * SS
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    C = 512.0
    k = big / 1024.0

    def T(v):
        return int(round((C + scale_fg * (v - C)) * k))

    def box(x0, y0, x1, y1):
        return [T(x0), T(y0), T(x1), T(y1)]

    def w(orig):
        return int(round(orig * k * scale_fg))

    if with_bg:
        d.rectangle([0, 0, big - 1, big - 1], fill=BG)

    # 外圈半透明声波
    wv = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    dw = ImageDraw.Draw(wv)
    wx, wy, wr = T(785), T(570), w(110)
    dw.arc([wx - wr, wy - wr, wx + wr, wy + wr], 305, 55,
           (255, 255, 255, 115), w(22))
    img.alpha_composite(wv)

    # 耳机横梁
    d.arc(box(300, 270, 725, 940), 180, 360, WHITE, w(62))
    # 耳罩
    for ox, inner in ((243, ORANGE), (647, YELLOW)):
        d.rounded_rectangle(box(ox, 578, ox + 135, 802), w(64), DARK)
        d.rounded_rectangle(box(ox + 32, 616, ox + 103, 762), w(36), inner)
    # 音符
    d.ellipse(box(152, 350, 228, 412), WHITE)
    d.rectangle(box(216, 248, 231, 388), WHITE)
    d.arc(box(150, 245, 320, 395), 270, 360, WHITE, w(16))
    # 内圈实色声波
    wx, wy, wr = T(785), T(570), w(55)
    d.arc([wx - wr, wy - wr, wx + wr, wy + wr], 305, 55, WHITE, w(22))

    return img.resize((S, S), Image.LANCZOS)


for folder, size in DENS.items():
    base = os.path.join(RES, folder)
    render(size, FG_SCALE, with_bg=True).save(
        os.path.join(base, "ic_launcher.png"))
    render(size, FG_SCALE, with_bg=False).save(
        os.path.join(base, "ic_launcher_foreground.png"))
    print("updated", folder)

# 背景色 -> #3A2B23
bg_path = os.path.join(RES, "values", "ic_launcher_background.xml")
with open(bg_path, "r", encoding="utf-8") as f:
    txt = f.read()
txt = txt.replace("#F98E5F", "#3A2B23")
with open(bg_path, "w", encoding="utf-8") as f:
    f.write(txt)
print("bg color -> #3A2B23")
