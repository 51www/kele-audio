# -*- coding: utf-8 -*-
"""基于 icon.png(1024) 生成多平台图标集到 icons/ 目录"""
import os
from PIL import Image

BASE = r"E:\www\kele-audio\docs\images\icon.png"
OUT = r"E:\www\kele-audio\docs\images\icons"
os.makedirs(OUT, exist_ok=True)

src = Image.open(BASE).convert("RGBA")


def save(name, size):
    img = src.resize((size, size), Image.LANCZOS)
    p = os.path.join(OUT, name)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    img.save(p)
    print("saved", name, size)


# 项目 logo
save("logo-256.png", 256)
save("logo-512.png", 512)

# Web favicon（合并多尺寸 .ico）
fav = os.path.join(OUT, "favicon.ico")
src.save(fav, sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
print("saved favicon.ico")

# Android mipmap 密度
for d, s in [("mipmap-mdpi", 48), ("mipmap-hdpi", 72),
             ("mipmap-xhdpi", 96), ("mipmap-xxhdpi", 144),
             ("mipmap-xxxhdpi", 192)]:
    save(os.path.join("android", d, "ic_launcher.png"), s)
# Android 自适应图标 + Play 商店
save(os.path.join("android", "play_store.png"), 512)

# iOS
ios = [20, 29, 40, 58, 60, 76, 80, 87, 120, 152, 167, 180, 1024]
for s in ios:
    save(os.path.join("ios", f"Icon-{s}.png"), s)

# Windows / 桌面 / Electron
for s in [16, 24, 32, 48, 64, 128, 256, 512]:
    save(os.path.join("windows", f"icon-{s}.png"), s)

print("done")
