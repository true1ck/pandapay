#!/usr/bin/env python3
"""Build Play Store screenshot slides from raw emulator screenshots.

Usage: make_carousel.py RAW_DIR OUT_DIR
RAW_DIR holds the raw PNGs named in SLIDES below. Output is 1080x1920 PNG
(9:16, inside Play's 2-8 phone screenshot rules). Edit SLIDES for new copy.
"""
import sys, os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H = 1080, 1920
INK = (17, 21, 26)
INK2 = (60, 70, 82)
GREEN = (74, 143, 42)
PHONE_W = 800

# (raw file, headline, subline). A raw file of None makes the brand slide.
SLIDES = [
    ("home.png", "Your money, one clear view", "Spending, cards and rewards together"),
    ("rewards.png", "See what your cards earn", "Rewards earned and what you left on the table"),
    ("activity.png", "Bank SMS become tidy transactions", "Merchant, card and reward on every row"),
    ("insights.png", "See where your money goes", "By category, merchant and month"),
    ("cards.png", "Know which card earns more", "Utilization and reward points per card"),
    ("splits.png", "Split bills with friends", "Who owes whom, settled in a tap"),
    ("sms_disclosure.png", "Clear consent before any SMS is read", "You choose, and can turn it off any time"),
    ("privacy.png", "Your messages stay on your phone", "Only transaction details sync"),
]

def font(size, bold=False):
    path = '/System/Library/Fonts/Supplemental/Arial Bold.ttf' if bold else '/System/Library/Fonts/Supplemental/Arial.ttf'
    return ImageFont.truetype(path, size)

def background():
    img = Image.new('RGB', (W, H), (255, 255, 255))
    d = ImageDraw.Draw(img)
    for y in range(H):
        t = y / H
        d.line([(0, y), (W, y)], fill=(int(255 * (1 - t) + 226 * t), int(255 * (1 - t) + 241 * t), int(255 * (1 - t) + 208 * t)))
    return img

def wrap(draw, text, fnt, max_w):
    words, lines, cur = text.split(), [], ''
    for w in words:
        trial = (cur + ' ' + w).strip()
        if draw.textlength(trial, font=fnt) <= max_w:
            cur = trial
        else:
            lines.append(cur); cur = w
    lines.append(cur)
    return lines

def phone(screen):
    sw = PHONE_W - 28
    sh = int(sw * screen.height / screen.width)
    scr = screen.convert('RGB').resize((sw, sh), Image.LANCZOS)
    mask = Image.new('L', (sw, sh), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, sw, sh], radius=54, fill=255)
    body = Image.new('RGBA', (PHONE_W, sh + 28), (0, 0, 0, 0))
    ImageDraw.Draw(body).rounded_rectangle([0, 0, PHONE_W - 1, sh + 27], radius=70, fill=(20, 24, 28, 255))
    body.paste(scr, (14, 14), mask)
    return body

def make(slide, raw_dir, out_dir, n):
    raw, head, sub = slide
    img = background()
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([90, 120, 150, 128], radius=4, fill=GREEN)
    hf, sf = font(74, True), font(40)
    y = 160
    for line in wrap(d, head, hf, W - 180):
        d.text((90, y), line, font=hf, fill=INK); y += 88
    d.text((90, y + 10), sub, font=sf, fill=INK2)
    p = phone(Image.open(os.path.join(raw_dir, raw)))
    px, py = (W - PHONE_W) // 2, 470
    shadow = Image.new('RGBA', img.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([px + 6, py + 26, px + PHONE_W + 6, py + p.height + 26], radius=70, fill=(0, 0, 0, 70))
    shadow = shadow.filter(ImageFilter.GaussianBlur(26))
    img = Image.alpha_composite(img.convert('RGBA'), shadow)
    img.alpha_composite(p, (px, py))
    out = os.path.join(out_dir, 'slide-%02d.png' % n)
    img.convert('RGB').save(out, optimize=True)
    return out

if __name__ == '__main__':
    raw_dir, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)
    n = 0
    for s in SLIDES:
        if os.path.exists(os.path.join(raw_dir, s[0])):
            n += 1
            print(make(s, raw_dir, out_dir, n))
        else:
            print('skip (missing raw):', s[0])
