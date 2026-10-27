#!/usr/bin/env python3
"""Renders the DMG window background (Support/dmg/background.png + @2x).

Layout must match the Finder positions used when the DMG is packaged:
window 660x420 pt, Mowa.app icon centred at (170, 190), Applications at (490, 190),
icon size 128. Run: python3 scripts/make-dmg-background.py   (needs Pillow)
"""
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H = 660, 420
APP_X, APPS_X, ICON_Y = 170, 490, 190
OUT = os.path.join(os.path.dirname(__file__), "..", "Support", "dmg")

BG_TOP = (255, 248, 245)      # --bg
BG_BOTTOM = (253, 234, 225)   # slightly warmer
GRAD_A = (255, 138, 92)       # --grad-a
GRAD_B = (232, 72, 74)        # --grad-b
TEXT = (31, 23, 20)           # --text
MUTED = (101, 85, 79)         # --muted

FONT_CANDIDATES = [
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
]
FONT_BOLD_CANDIDATES = [
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
]


def font(cands, size):
    for c in cands:
        if os.path.exists(c):
            try:
                return ImageFont.truetype(c, size)
            except OSError:
                pass
    return ImageFont.load_default()


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def render(scale):
    w, h = W * scale, H * scale
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        c = lerp(BG_TOP, BG_BOTTOM, y / (h - 1))
        for x in range(w):
            px[x, y] = c

    # soft glow behind the arrow
    glow = Image.new("L", (w, h), 0)
    ImageDraw.Draw(glow).ellipse(
        [(W / 2 - 110) * scale, (ICON_Y - 70) * scale, (W / 2 + 110) * scale, (ICON_Y + 70) * scale], fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(40 * scale))
    img = Image.composite(Image.new("RGB", (w, h), (255, 214, 196)), img, glow)

    # arrow: gradient shaft + head, drawn on a mask then filled with a gradient
    mask = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(mask)
    x0, x1 = (APP_X + 92) * scale, (APPS_X - 92) * scale
    y = ICON_Y * scale
    t = 7 * scale
    head = 22 * scale
    d.rounded_rectangle([x0, y - t, x1 - head + 4 * scale, y + t], radius=t, fill=255)
    d.polygon([(x1 - head - 6 * scale, y - 2.6 * t), (x1, y), (x1 - head - 6 * scale, y + 2.6 * t)], fill=255)
    grad = Image.new("RGB", (w, h))
    gp = grad.load()
    for x in range(int(x0), int(x1) + 1):
        c = lerp(GRAD_A, GRAD_B, (x - x0) / max(1, x1 - x0))
        for yy in range(int(y - 3 * t), int(y + 3 * t) + 1):
            gp[x, yy] = c
    img = Image.composite(grad, img, mask)

    d = ImageDraw.Draw(img)
    title = font(FONT_BOLD_CANDIDATES, 19 * scale)
    body = font(FONT_CANDIDATES, 13 * scale)
    t1 = "Drag Mowa into Applications to install"
    t2 = "Then open Mowa from Applications. It runs in the menu bar at the top of the screen."
    for text, f, color, ty in ((t1, title, TEXT, 318), (t2, body, MUTED, 350)):
        tw = d.textlength(text, font=f)
        d.text(((w - tw) / 2, ty * scale), text, font=f, fill=color)
    return img


os.makedirs(OUT, exist_ok=True)
render(1).save(os.path.join(OUT, "background.png"), dpi=(72, 72))
render(2).save(os.path.join(OUT, "background@2x.png"), dpi=(144, 144))
print("wrote", os.path.abspath(OUT))
