# -*- coding: utf-8 -*-
"""重绘 kele-audio 图标：#3A2B23 纯色背景 + 前景缩小居中(留白加大)"""
from PIL import Image, ImageDraw

S = 4                      # 4x 超采样抗锯齿
SIZE = 1024 * S
BG = (58, 43, 35, 255)     # #3A2B23
WHITE = (255, 255, 255, 255)
DARK = (46, 42, 75, 255)   # 耳罩深色
ORANGE = (245, 138, 91, 255)
YELLOW = (242, 178, 75, 255)
SCALE = 0.80               # 前景缩放，留白加大
C = 512.0

def tx(v):
    return int(round((C + SCALE * (v - C)) * S))

def box(x0, y0, x1, y1):
    return [tx(x0), tx(y0), tx(x1), tx(y1)]

img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# 背景：圆角矩形（圆角约 22%）
r = int(0.22 * SIZE)
d.rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=r, fill=BG)

# 半透光外圈声波（画在底层）
wave = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
dw = ImageDraw.Draw(wave)
wx, wy, wr = tx(785), tx(570), int(110 * S * SCALE)
dw.arc([wx - wr, wy - wr, wx + wr, wy + wr], start=305, end=55,
       fill=(255, 255, 255, 115), width=int(22 * S * SCALE))
img.alpha_composite(wave)

# 耳机横梁（拱形）
d.arc(box(300, 270, 725, 940), start=180, end=360, fill=WHITE,
      width=int(62 * S * SCALE))

# 耳罩：左（橙芯）右（黄芯）
for ox, inner in ((243, ORANGE), (647, YELLOW)):
    d.rounded_rectangle(box(ox, 578, ox + 135, 802),
                        radius=int(64 * S * SCALE), fill=DARK)
    d.rounded_rectangle(box(ox + 32, 616, ox + 103, 762),
                        radius=int(36 * S * SCALE), fill=inner)

# 音符（符头 + 符干 + 符尾）
d.ellipse(box(152, 350, 228, 412), fill=WHITE)          # 符头
d.rectangle(box(216, 248, 231, 388), fill=WHITE)        # 符干
d.arc(box(150, 245, 320, 395), start=270, end=360, fill=WHITE,
      width=int(16 * S * SCALE))                        # 符尾

# 内圈声波（实色）
wx, wy, wr = tx(785), tx(570), int(55 * S * SCALE)
d.arc([wx - wr, wy - wr, wx + wr, wy + wr], start=305, end=55,
      fill=WHITE, width=int(22 * S * SCALE))

img = img.resize((1024, 1024), Image.LANCZOS)
img.save(r"E:\www\kele-audio\docs\images\icon.png")
print("saved")
