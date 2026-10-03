#!/usr/bin/env python3
"""Build the AI Music Radar App Store screenshots (same peach marketing style as omr-sheet-cam).

Outputs to docs/asc/screenshots/en-US/ (PNG, RGB, no alpha), picked up by scripts/asc/upload_music_reader_listing.py:
  iphone-69-NN-*.png  1320x2868  APP_IPHONE_67
  ipad-13-NN-*.png    2064x2752  APP_IPAD_PRO_3GEN_129
Layout/typography/colors/framing follow omr-sheet-cam docs/asc/screenshots/en-US/make_store_screenshots.py:
peach gradient, big Inter ExtraBold caption at the top, graphite device frame with a soft shadow, card + chips.

The app screens are redrawn here (vector, at device resolution) from docs/ui-mockups/ and the real SwiftUI
views in Sources/App (LibraryView, SheetDetailView, StaffPageView / Engraver, PianoRoll). Only UI the app has is shown:
library (samples + My Takes, mic button, Import audio), sheet detail (title, BPM/meter/key caption,
Page / Piano roll picker, engraved grand staff, yellow playback highlight, play / share / save-photo buttons).
The tune is an original 12-bar melody written for these screenshots. Store copy never claims real-time.
Usage: python3 tools/asc-screenshots/make_store_screenshots.py   (Pillow + numpy; Inter + Source Serif Pro fonts;
Noto Music (OFL) is vendored in fonts/)
"""
from pathlib import Path
import math
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = ROOT / "docs/asc/screenshots/en-US"
FONT = "/usr/share/fonts/truetype/sand-box/google/Inter/Inter-VariableFont_opsz,wght.ttf"
SERIF = "/usr/share/fonts/truetype/sand-box/custom/Source Serif Pro/SourceSerifPro-Regular.ttf"
MUSIC = str(HERE / "fonts/NotoMusic-Regular.ttf")
INK = (38, 20, 16)          # caption ink (omr)
SUB = (110, 60, 48)
SIZES = {"iphone-69": (1320, 2868), "ipad-13": (2064, 2752)}

# App palette (Sources/App/ListeningView.swift, enum Ink) + iOS system colors.
PAPER = (250, 248, 242)
AINK = (28, 28, 28)
TEAL = (12, 107, 107)
SECOND = (134, 134, 139)
SEP = (222, 220, 214)
BLUE = (0, 122, 255)
TEAL_SOFT = (190, 214, 211)

SHOTS = [
    ("01-hear-it", "Hear it.\nThen read it.", "Record a take or import audio"),
    ("02-sheet-music", "Real sheet music\nin seconds", "Tempo, meter and key, detected"),
    ("03-playback", "Every note lights\nup as it plays", "Play it back right on the page"),
    ("04-piano-roll", "Check it on\nthe piano roll", "Switch between Page and Piano roll"),
    ("05-export", "Export MIDI,\nMusicXML & PDF", "On-device. No upload. No account."),
]


def font(size, weight="ExtraBold"):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(weight)
    return f


# ---------------------------------------------------------------- marketing frame (from omr)

def peach_bg(W, H):
    y = np.linspace(0, 1, H)[:, None]
    x = np.linspace(0, 1, W)[None, :]
    top = np.array([250, 214, 196], float)
    bot = np.array([240, 172, 150], float)
    img = top[None, None, :] * (1 - y[..., None]) + bot[None, None, :] * y[..., None]
    d = np.sqrt(((x - 0.5) * W / H) ** 2 + (y - 0.42) ** 2)
    glow = np.clip(1 - d / 0.55, 0, 1) ** 2 * 18
    img = img + glow[..., None]
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB")


def draw_caption(canvas, text, sub, scale):
    d = ImageDraw.Draw(canvas)
    W = canvas.width
    f = font(round(126 * scale))
    y = round(150 * scale)
    lh = round(146 * scale)
    for line in text.split("\n"):
        w = d.textlength(line, font=f)
        assert w <= W - 2 * 60 * scale, (line, w)
        d.text(((W - w) / 2, y), line, font=f, fill=INK)
        y += lh
    if sub:
        fs = font(round(58 * scale), "SemiBold")
        y += round(22 * scale)
        w = d.textlength(sub, font=fs)
        assert w <= W - 2 * 60 * scale, (sub, w)
        d.text(((W - w) / 2, y), sub, font=fs, fill=SUB)
        y += round(70 * scale)
    return y


def rounded_mask(size, r):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), r, fill=255)
    return m


def drop_shadow(canvas, box, r, blur, offset, alpha):
    x0, y0, x1, y1 = box
    pad = blur * 3
    sh = Image.new("L", (x1 - x0 + 2 * pad, y1 - y0 + 2 * pad), 0)
    ImageDraw.Draw(sh).rounded_rectangle((pad, pad, pad + x1 - x0, pad + y1 - y0), r, fill=alpha)
    sh = sh.filter(ImageFilter.GaussianBlur(blur))
    dark = Image.new("RGB", sh.size, (120, 50, 35))
    canvas.paste(dark, (x0 - pad, y0 - pad + offset), sh)


def device(canvas, screen, cx, top, screen_w, radius=0.14, bezel=0.036):
    """Graphite device frame (omr phone()); iPad uses a smaller corner radius."""
    sw = screen_w
    sh = round(screen.height * sw / screen.width)
    b = round(sw * bezel)
    R = round(sw * radius)
    pw, ph = sw + 2 * b, sh + 2 * b
    x0 = round(cx - pw / 2)
    drop_shadow(canvas, (x0, top, x0 + pw, top + ph), R, round(sw * 0.05), round(sw * 0.04), 150)
    body = Image.new("RGB", (pw, ph), (58, 58, 62))
    inner = Image.new("RGB", (pw - 6, ph - 6), (22, 22, 24))
    body.paste(inner, (3, 3), rounded_mask(inner.size, R - 3))
    canvas.paste(body, (x0, top), rounded_mask((pw, ph), R))
    scr = screen.resize((sw, sh), Image.LANCZOS)
    canvas.paste(scr, (x0 + b, top + b), rounded_mask((sw, sh), max(8, R - b)))
    return top + ph


def card(canvas, img, cx, cy, width, r):
    h = round(img.height * width / img.width)
    im = img.resize((width, h), Image.LANCZOS)
    x0, y0 = round(cx - width / 2), round(cy - h / 2)
    drop_shadow(canvas, (x0, y0, x0 + width, y0 + h), r, round(width * 0.04), round(width * 0.03), 140)
    canvas.paste(im, (x0, y0), rounded_mask(im.size, r))
    return y0, y0 + h


def chip_grid(canvas, labels, top, scale, highlight=None):
    d = ImageDraw.Draw(canvas)
    f = font(round(54 * scale), "SemiBold")
    h, gx, gy = round(118 * scale), round(26 * scale), round(28 * scale)
    padx = round(46 * scale)
    maxw = canvas.width - round(140 * scale)
    rows, row, rw = [], [], 0
    for lab in labels:
        w = int(d.textlength(lab, font=f)) + 2 * padx
        if row and rw + gx + w > maxw:
            rows.append((row, rw)); row, rw = [], 0
        row.append((lab, w)); rw += (gx if rw else 0) + w
    rows.append((row, rw))
    y = top
    for row, rw in rows:
        x = (canvas.width - rw) // 2
        for lab, w in row:
            col = (226, 96, 70) if lab == highlight else (20, 20, 22)
            d.rounded_rectangle((x, y, x + w, y + h), h // 2, fill=col)
            tb = d.textbbox((0, 0), lab, font=f)
            d.text((x + padx, y + h / 2 - (tb[1] + tb[3]) / 2), lab, font=f, fill="white")
            x += w + gx
        y += h + gy
    return y


# ---------------------------------------------------------------- the score (original tune, G major, 4/4)
# (pitch or None, duration in eighths). Treble melody + bass half notes; 12 bars.
TREBLE = [
    [("G4", 2), ("B4", 1), ("D5", 1), ("G5", 2), ("F#5", 1), ("E5", 1)],
    [("D5", 2), ("B4", 2), ("C5", 1), ("B4", 1), ("A4", 2)],
    [("B4", 1), ("C5", 1), ("D5", 2), ("G5", 2), ("D5", 2)],
    [("E5", 2), ("C5", 1), ("E5", 1), ("D5", 2), ("B4", 2)],
    [("A4", 1), ("B4", 1), ("C5", 2), ("B4", 1), ("A4", 1), ("G4", 2)],
    [("A4", 2), ("D5", 2), ("F#4", 2), ("A4", 2)],
    [("G4", 1), ("A4", 1), ("B4", 1), ("C5", 1), ("D5", 2), ("E5", 2)],
    [("D5", 2), ("B4", 2), ("A4", 2), ("G4", 2)],
    [("E5", 1), ("D5", 1), ("C5", 1), ("B4", 1), ("A4", 4)],
    [("B4", 2), ("A4", 2), ("G4", 4)],
    [("G4", 2), ("B4", 2), ("D5", 2), ("G5", 2)],
    [("F#5", 1), ("E5", 1), ("D5", 2), ("G5", 4)],
    [("B4", 2), ("D5", 1), ("C5", 1), ("B4", 2), ("A4", 2)],
    [("G4", 1), ("A4", 1), ("B4", 2), ("E5", 2), ("D5", 2)],
    [("C5", 2), ("A4", 2), ("B4", 1), ("G4", 1), ("A4", 2)],
    [("G4", 8)],
]
BASS = [["G2", "D3"], ["C3", "D3"], ["G2", "B2"], ["C3", "G2"], ["D3", "G2"], ["D3", "D3"],
        ["G2", "C3"], ["D3", "G2"], ["C3", "D3"], ["D3", "G2"], ["G2", "B2"], ["D3", "G2"],
        ["G2", "D3"], ["C3", "G2"], ["C3", "D3"], ["G2", "G2"]]
STEPS = {"C": 0, "D": 1, "E": 2, "F": 3, "G": 4, "A": 5, "B": 6}
SEMI = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
TEMPO, NOTE_COUNT = 96, sum(len(b) for b in TREBLE) + 2 * len(BASS)
TAKE = "Take 3"
DURATION = f"0:{round(len(TREBLE) * 4 * 60 / TEMPO):02d}"
CAPTION = f"{TEMPO} BPM \u00b7 4/4 \u00b7 G major \u00b7 {NOTE_COUNT} notes"
HILITE = (4, 2)  # (bar, index) of the treble note lit up during playback, + the bass note under it


def diatonic(p):
    return STEPS[p[0]] + 7 * int(p[-1])


def midi(p):
    return 12 * (int(p[-1]) + 1) + SEMI[p[0]] + (1 if "#" in p else 0)


# ---------------------------------------------------------------- screen canvas (points -> pixels)

class Screen:
    def __init__(self, wpt, hpt, k, ipad=False):
        self.w, self.h, self.k, self.ipad = wpt, hpt, k, ipad
        self.im = Image.new("RGB", (round(wpt * k), round(hpt * k)), PAPER)
        self.d = ImageDraw.Draw(self.im)

    def P(self, *v):
        return [round(x * self.k) for x in v]

    def f(self, size, weight="Regular", path=FONT):
        fo = ImageFont.truetype(path, round(size * self.k))
        if path == FONT:
            fo.set_variation_by_name(weight)
        return fo

    def text(self, x, y, s, size, fill=AINK, weight="Regular", anchor="la", path=FONT):
        self.d.text(self.P(x, y), s, font=self.f(size, weight, path), fill=fill, anchor=anchor)

    def tlen(self, s, size, weight="Regular", path=FONT):
        return self.d.textlength(s, font=self.f(size, weight, path)) / self.k

    def rect(self, x0, y0, x1, y1, fill=None, r=0, outline=None, width=1):
        if r:
            self.d.rounded_rectangle(self.P(x0, y0, x1, y1), round(r * self.k), fill=fill, outline=outline,
                                     width=max(1, round(width * self.k)))
        else:
            self.d.rectangle(self.P(x0, y0, x1, y1), fill=fill, outline=outline, width=max(1, round(width * self.k)) if outline else 0)

    def ellipse(self, cx, cy, r, fill=None, outline=None, width=1):
        self.d.ellipse(self.P(cx - r, cy - r, cx + r, cy + r), fill=fill, outline=outline, width=max(1, round(width * self.k)))

    def line(self, pts, fill=AINK, width=1.0):
        self.d.line([tuple(self.P(x, y)) for x, y in pts], fill=fill, width=max(1, round(width * self.k)), joint="curve")

    def poly(self, pts, fill):
        self.d.polygon([tuple(self.P(x, y)) for x, y in pts], fill=fill)

    # --- system chrome
    def status_bar(self):
        if self.ipad:
            y = 14
            self.text(28, y, "9:41", 15, AINK, "SemiBold", "lm")
            self.text(96, y, "Sat Oct 3", 15, AINK, "SemiBold", "lm")
            self._status_icons(self.w - 28, y, 0.9)
        else:
            y = 31
            self.text(66, y, "9:41", 17.5, AINK, "SemiBold", "mm")
            self.rect(self.w / 2 - 63, 11, self.w / 2 + 63, 48, fill=(0, 0, 0), r=18.5)  # Dynamic Island
            self._status_icons(self.w - 30, y, 1.0)

    def _status_icons(self, right, cy, s):
        # battery
        bw, bh = 25 * s, 12 * s
        x1 = right - 3 * s
        self.rect(x1 - bw, cy - bh / 2, x1, cy + bh / 2, outline=(150, 150, 150), r=3.5 * s, width=1)
        self.rect(x1 - bw + 2 * s, cy - bh / 2 + 2 * s, x1 - 2 * s, cy + bh / 2 - 2 * s, fill=AINK, r=2 * s)
        self.rect(x1 + 1 * s, cy - 2.5 * s, x1 + 2.5 * s, cy + 2.5 * s, fill=(150, 150, 150), r=1)
        # wifi
        wx = x1 - bw - 15 * s
        for i, r in enumerate((11 * s, 7.3 * s, 3.6 * s)):
            box = self.P(wx - r, cy + 5 * s - r, wx + r, cy + 5 * s + r)
            if i < 2:
                self.d.arc(box, 225, 315, fill=AINK, width=max(2, round(2.2 * s * self.k)))
            else:
                self.d.pieslice(box, 225, 315, fill=AINK)
        # signal
        sx = wx - 34 * s
        for i in range(4):
            hh = (4 + 2.6 * i) * s
            self.rect(sx + i * 5 * s, cy + 5.5 * s - hh, sx + i * 5 * s + 3.2 * s, cy + 5.5 * s, fill=AINK, r=1)

    def home_indicator(self):
        w = 140 if not self.ipad else 320
        self.rect(self.w / 2 - w / 2, self.h - 13, self.w / 2 + w / 2, self.h - 8, fill=AINK, r=2.5)

    # --- SF-symbol-like icons
    def play_circle(self, cx, cy, r, hierarchical=False, pause=False):
        if hierarchical:
            self.ellipse(cx, cy, r, fill=TEAL_SOFT)
            fg = TEAL
        else:
            self.ellipse(cx, cy, r, fill=TEAL)
            fg = PAPER
        if pause:
            bw, bh = r * 0.17, r * 0.78
            for dx in (-r * 0.22, r * 0.22):
                self.rect(cx + dx - bw / 2, cy - bh / 2, cx + dx + bw / 2, cy + bh / 2, fill=fg, r=bw * 0.3)
        else:
            a = r * 0.42
            self.poly([(cx - a * 0.7, cy - a), (cx - a * 0.7, cy + a), (cx + a * 1.05, cy)], fg)

    def chevron(self, x, cy, size, fill=(196, 196, 199), width=2.2, left=False):
        dx = -size * 0.5 if left else size * 0.5
        self.line([(x - dx, cy - size), (x + dx, cy), (x - dx, cy + size)], fill, width)

    def share_icon(self, cx, cy, s, fill=AINK, down=False, width=2.0):
        # open-top box + arrow (square.and.arrow.up / .down)
        self.line([(cx - s * 0.32, cy - s * 0.12), (cx - s * 0.5, cy - s * 0.12), (cx - s * 0.5, cy + s * 0.55),
                   (cx + s * 0.5, cy + s * 0.55), (cx + s * 0.5, cy - s * 0.12), (cx + s * 0.32, cy - s * 0.12)], fill, width)
        if down:
            self.line([(cx, cy - s * 0.62), (cx, cy + s * 0.25)], fill, width)
            self.line([(cx - s * 0.22, cy + s * 0.03), (cx, cy + s * 0.25), (cx + s * 0.22, cy + s * 0.03)], fill, width)
        else:
            self.line([(cx, cy - s * 0.66), (cx, cy + s * 0.22)], fill, width)
            self.line([(cx - s * 0.22, cy - s * 0.44), (cx, cy - s * 0.66), (cx + s * 0.22, cy - s * 0.44)], fill, width)

    def photo_icon(self, cx, cy, s, fill=AINK, width=2.0):
        self.rect(cx - s * 0.55, cy - s * 0.42, cx + s * 0.55, cy + s * 0.42, outline=fill, r=s * 0.14, width=width)
        self.line([(cx - s * 0.45, cy + s * 0.3), (cx - s * 0.12, cy - s * 0.05), (cx + s * 0.1, cy + s * 0.15),
                   (cx + s * 0.25, cy + s * 0.02), (cx + s * 0.45, cy + s * 0.25)], fill, width)
        self.ellipse(cx + s * 0.22, cy - s * 0.17, s * 0.08, fill=fill)

    def mic(self, cx, cy, s, fill="white"):
        self.rect(cx - s * 0.2, cy - s * 0.55, cx + s * 0.2, cy + s * 0.12, fill=fill, r=s * 0.2)
        self.d.arc(self.P(cx - s * 0.36, cy - s * 0.4, cx + s * 0.36, cy + s * 0.32), 0, 180, fill=fill,
                   width=max(2, round(s * 0.08 * self.k)))
        self.line([(cx, cy + s * 0.32), (cx, cy + s * 0.5)], fill, s * 0.08)
        self.line([(cx - s * 0.18, cy + s * 0.5), (cx + s * 0.18, cy + s * 0.5)], fill, s * 0.08)


# ---------------------------------------------------------------- engraving (Engraver.swift look: grand staff)

def engrave(sc, x0, top, width, bars_per_sys, gap=9.0, hilite=None, max_systems=None):
    """Draws grand-staff systems; returns bottom y. hilite = set of (bar, kind, idx) to mark yellow."""
    systems = [list(range(i, min(i + bars_per_sys, len(TREBLE)))) for i in range(0, len(TREBLE), bars_per_sys)]
    if max_systems:
        systems = systems[:max_systems]
    y = top
    staff_dist = 7.5 * gap
    marks = []
    for si, bars in enumerate(systems):
        t_top, b_top = y, y + staff_dist
        for st in (t_top, b_top):
            for i in range(5):
                sc.line([(x0, st + i * gap), (x0 + width, st + i * gap)], AINK, 0.9)
        sc.line([(x0, t_top), (x0, b_top + 4 * gap)], AINK, 1.0)
        # clefs + key signature (F#), fitted by glyph bbox
        glyph_fit(sc, "\U0001D11E", x0 + 5, t_top - 1.7 * gap, 7.4 * gap)
        glyph_fit(sc, "\U0001D122", x0 + 6, b_top - 0.05 * gap, 3.3 * gap)
        kx = x0 + 36
        glyph_fit(sc, "\u266F", kx, t_top - 1.3 * gap, 2.6 * gap)
        glyph_fit(sc, "\u266F", kx, b_top + gap - 1.3 * gap, 2.6 * gap)
        cx = kx + 12
        if si == 0:
            for st in (t_top, b_top):
                sc.text(cx + 6, st + gap, "4", gap * 2.3, AINK, "Black", "mm")
                sc.text(cx + 6, st + 3 * gap, "4", gap * 2.3, AINK, "Black", "mm")
            cx += 22
        cx += 6
        bw = (x0 + width - cx) / len(bars)
        for j, b in enumerate(bars):
            bx = cx + j * bw
            slot = (bw - 10) / 8
            # treble
            groups, cur = [], []
            pos = 0
            heads = []
            for idx, (p, du) in enumerate(TREBLE[b]):
                hx = bx + 8 + pos * slot + slot * 0.5
                hy = t_top + 4 * gap - (diatonic(p) - diatonic("E4")) * gap / 2
                heads.append((hx, hy, du, idx))
                pos += du
            draw_voice(sc, heads, t_top, gap, ("t", b), hilite, marks)
            bh = []
            for idx, p in enumerate(BASS[b]):
                hx = bx + 8 + idx * 4 * slot + slot * 0.5
                hy = b_top + 4 * gap - (diatonic(p) - diatonic("G2")) * gap / 2
                bh.append((hx, hy, 4, idx))
            draw_voice(sc, bh, b_top, gap, ("b", b), hilite, marks)
            last = b == len(TREBLE) - 1
            xe = bx + bw
            if last:
                sc.line([(xe - 4, t_top), (xe - 4, b_top + 4 * gap)], AINK, 1.0)
                sc.line([(xe - 1, t_top), (xe - 1, b_top + 4 * gap)], AINK, 3.0)
            else:
                sc.line([(xe, t_top), (xe, b_top + 4 * gap)], AINK, 1.0)
        if si == 0:
            pass
        y = b_top + 4 * gap + 6.5 * gap
    for (hx, hy, gp) in marks:  # StaffPageView: systemYellow @ 0.45 ellipse around the head, inset -4
        ov = Image.new("RGBA", sc.im.size, (0, 0, 0, 0))
        ImageDraw.Draw(ov).ellipse(sc.P(hx - gp * 0.62 - 4, hy - gp * 0.45 - 4, hx + gp * 0.62 + 4, hy + gp * 0.45 + 4),
                                   fill=(255, 204, 0, 115))
        sc.im.paste(Image.alpha_composite(sc.im.convert("RGBA"), ov).convert("RGB"))
    return y - 6.5 * gap


def glyph_fit(sc, g, x, top, height):
    probe = ImageFont.truetype(MUSIC, 1000)
    l, t, r, b = probe.getbbox(g, anchor="ls")
    size = height * 1000 / (b - t)
    f = ImageFont.truetype(MUSIC, round(size * sc.k))
    l, t, r, b = f.getbbox(g, anchor="ls")
    sc.d.text((round(x * sc.k) - l, round(top * sc.k) - t), g, font=f, fill=AINK, anchor="ls")


def head(sc, hx, hy, gap, filled):
    hw, hh, a = gap * 0.62, gap * 0.45, -0.35
    pts = []
    for i in range(36):
        t = 2 * math.pi * i / 36
        x, yv = hw * math.cos(t), hh * math.sin(t)
        pts.append((hx + x * math.cos(a) - yv * math.sin(a), hy + x * math.sin(a) + yv * math.cos(a)))
    if filled:
        sc.poly(pts, AINK)
    else:
        sc.line(pts + [pts[0]], AINK, 1.6)


def draw_voice(sc, heads, st, gap, key, hilite, marks):
    mid = st + 2 * gap
    i = 0
    while i < len(heads):
        hx, hy, du, idx = heads[i]
        # ledger lines
        yy = st + 5 * gap
        while hy >= yy - 0.1:
            sc.line([(hx - gap * 0.85, yy), (hx + gap * 0.85, yy)], AINK, 1.0); yy += gap
        yy = st - gap
        while hy <= yy + 0.1:
            sc.line([(hx - gap * 0.85, yy), (hx + gap * 0.85, yy)], AINK, 1.0); yy -= gap
        head(sc, hx, hy, gap, filled=du <= 2)
        if hilite and (key[0], key[1], idx) in hilite:
            marks.append((hx, hy, gap))
        if du == 1:  # beam group of consecutive eighths
            grp = [heads[i]]
            j = i + 1
            while j < len(heads) and heads[j][2] == 1 and len(grp) < 4:
                grp.append(heads[j]); j += 1
            for g in grp[1:]:
                yy = g[0]
            if len(grp) > 1:
                for g in grp[1:]:
                    gx, gy, _, gidx = g
                    yy2 = st + 5 * gap
                    while gy >= yy2 - 0.1:
                        sc.line([(gx - gap * 0.85, yy2), (gx + gap * 0.85, yy2)], AINK, 1.0); yy2 += gap
                    head(sc, gx, gy, gap, True)
                    if hilite and (key[0], key[1], gidx) in hilite:
                        marks.append((gx, gy, gap))
                up = sum(g[1] for g in grp) / len(grp) > mid
                sx = [g[0] + (gap * 0.55 if up else -gap * 0.55) for g in grp]
                ext = min(g[1] for g in grp) - 3.4 * gap if up else max(g[1] for g in grp) + 3.4 * gap
                slope = max(-gap, min(gap, (grp[-1][1] - grp[0][1]) * 0.35))
                by = lambda x: ext + slope * (x - sx[0]) / max(1, sx[-1] - sx[0]) - slope / 2
                for g, x in zip(grp, sx):
                    sc.line([(x, g[1] + (-2 if up else 2)), (x, by(x))], AINK, 1.2)
                t = gap * 0.5 * (1 if up else -1)
                sc.poly([(sx[0], by(sx[0])), (sx[-1], by(sx[-1])), (sx[-1], by(sx[-1]) + t), (sx[0], by(sx[0]) + t)], AINK)
                i = j
                continue
        if du < 8:
            up = hy > mid
            x = hx + (gap * 0.55 if up else -gap * 0.55)
            sc.line([(x, hy + (-2 if up else 2)), (x, hy - 3.5 * gap if up else hy + 3.5 * gap)], AINK, 1.2)
            if du == 1:
                ye = hy - 3.5 * gap if up else hy + 3.5 * gap
                sc.line([(x, ye), (x + gap * 0.8, ye + (gap * 1.6 if up else -gap * 1.6))], AINK, 1.6)
        i += 1


def piano_roll(sc, x0, y0, w, h, hilite_idx=()):
    """PianoRoll.draw: gray 0.96 bg, beat grid, shaded black-key rows, blue bars, red-orange highlight."""
    events = []  # (start16, len16, midi, is_hilite)
    for b in range(len(TREBLE)):
        pos = 0
        for idx, (p, du) in enumerate(TREBLE[b]):
            events.append((b * 16 + pos * 2, du * 2, midi(p), ("t", b, idx) in hilite_idx)); pos += du
        for idx, p in enumerate(BASS[b]):
            events.append((b * 16 + idx * 8, 8, midi(p), ("b", b, idx) in hilite_idx))
    lo, hi = min(e[2] for e in events), max(e[2] for e in events)
    total = 16 * len(TREBLE)
    rows = hi - lo + 1
    cw, rh = w / total, h / rows
    sc.rect(x0, y0, x0 + w, y0 + h, fill=(245, 245, 245))
    for m in range(lo, hi + 1):
        if m % 12 in (1, 3, 6, 8, 10):
            yy = y0 + (hi - m) * rh
            sc.rect(x0, yy, x0 + w, yy + rh, fill=(230, 230, 230))
    for t in range(0, total + 1, 4):
        sc.line([(x0 + t * cw, y0), (x0 + t * cw, y0 + h)], (217, 217, 217), 0.5)
    for s16, l16, m, hl in events:
        yy = y0 + (hi - m) * rh + rh * 0.1
        sc.rect(x0 + s16 * cw, yy, x0 + s16 * cw + max(2, l16 * cw - 1), yy + rh * 0.8,
                fill=(230, 77, 51) if hl else (51, 115, 217))


# ---------------------------------------------------------------- app screens

def make_screen(ipad):
    return Screen(860, 1146.67, 2.4, ipad=True) if ipad else Screen(440, 956, 3)


def library_screen(ipad):
    sc = make_screen(ipad)
    sc.status_bar()
    top = 34 if ipad else 62
    # toolbar: Import audio (square.and.arrow.down), system blue
    sc.share_icon(sc.w - (34 if ipad else 30), top + 20, 24, BLUE, down=True, width=2.1)
    sc.text(20 if not ipad else 28, top + 50, "Sheets", 34, AINK, "Bold")
    mx = 20 if not ipad else 28  # inset-grouped list margins
    y = top + 112
    rows = [("SAMPLES", [("C Major Scale", "Sample \u00b7 8 notes \u00b7 0:04")]),
            ("MY TAKES", [("Take 5", "Today \u00b7 58 notes \u00b7 0:22"),
                          ("Take 4", "Today \u00b7 33 notes \u00b7 0:15"),
                          ("Take 3", f"Today \u00b7 {NOTE_COUNT} notes \u00b7 {DURATION}"),
                          ("Take 2", "Yesterday \u00b7 41 notes \u00b7 0:18"),
                          ("Take 1", "Oct 1, 2026 \u00b7 27 notes \u00b7 0:12")])]
    for hdr, items in rows:
        sc.text(mx + 16, y, hdr, 13, SECOND, "Medium")
        y += 26
        for n, (t, s) in enumerate(items):
            rh = 66
            sc.play_circle(mx + 16 + 19, y + rh / 2, 19, hierarchical=True)
            sc.text(mx + 16 + 52, y + rh / 2 - 11, t, 17, AINK, "SemiBold", "lm")
            sc.text(mx + 16 + 52, y + rh / 2 + 12, s, 15, SECOND, "Regular", "lm")
            sc.chevron(sc.w - mx - 22, y + rh / 2, 6.5)
            if n < len(items) - 1:
                sc.line([(mx + 16 + 52, y + rh), (sc.w - mx, y + rh)], SEP, 0.6)
            y += rh
        y += 30
    # floating mic button (Ink.teal, 76pt, shadow)
    cy = sc.h - (28 + 38 + 30) - (10 if ipad else 0)
    cx = sc.w / 2
    sh = Image.new("L", sc.im.size, 0)
    ImageDraw.Draw(sh).ellipse(sc.P(cx - 38, cy - 38 + 4, cx + 38, cy + 38 + 4), fill=70)
    sh = sh.filter(ImageFilter.GaussianBlur(10 * sc.k))
    sc.im.paste(Image.new("RGB", sc.im.size, (0, 0, 0)), (0, 0), sh)
    sc.ellipse(cx, cy, 38, fill=TEAL)
    sc.mic(cx, cy, 34)
    sc.home_indicator()
    return sc.im


def detail_screen(ipad, mode="page", playing=False):
    sc = make_screen(ipad)
    sc.status_bar()
    top = 34 if ipad else 62
    # nav bar: back to Sheets
    sc.chevron(18 if not ipad else 26, top + 20, 9.5, BLUE, 2.8, left=True)
    sc.text(32 if not ipad else 40, top + 20, "Sheets", 17, BLUE, "Regular", "lm")
    y = top + 52
    sc.text(sc.w / 2, y, TAKE, 24, AINK, anchor="mt", path=SERIF)
    y += 38
    sc.text(sc.w / 2, y, CAPTION, 15, SECOND, "Regular", "mt")
    y += 34
    # segmented picker
    px0, px1 = 16, sc.w - 16
    if ipad:
        px0, px1 = 24, sc.w - 24
    sc.rect(px0, y, px1, y + 32, fill=(232, 231, 226), r=9)
    half = (px1 - px0) / 2
    sel = 0 if mode == "page" else 1
    sx = px0 + 2 + sel * half
    sc.rect(sx, y + 2, sx + half - 4, y + 30, fill=(255, 255, 255), r=7)
    for i, lab in enumerate(("Page", "Piano roll")):
        sc.text(px0 + half * i + half / 2, y + 16, lab, 13.5, AINK, "SemiBold" if i == sel else "Medium", "mm")
    y += 32 + 8
    hl = {("t",) + HILITE, ("b", HILITE[0], 0)} if playing else None
    if mode == "page":
        bars = 3 if not ipad else 4
        probe = Screen(sc.w, sc.h, 0.5)
        bottom = engrave(probe, 18, y + 36, sc.w - 36, bars, gap=9.0)
        clip = sc.h - 34 - 14 - 52 - 22
        sc.rect(4, y, sc.w - 4, min(clip, bottom + 36), fill=(255, 255, 255))
        engrave(sc, 18, y + 36, sc.w - 36, bars, gap=9.0, hilite=hl)
        sc.rect(0, clip, sc.w, sc.h, fill=PAPER)
    else:
        piano_roll(sc, 16 if not ipad else 24, y, sc.w - (32 if not ipad else 48), 300, hl or ())
    # bottom controls: play/pause 52pt, share 28pt, save photo 28pt (spacing 32)
    cy = sc.h - 34 - 14 - 26
    sp = 32
    total = 52 + sp + 30 + sp + 30
    x = sc.w / 2 - total / 2
    sc.play_circle(x + 26, cy, 26, pause=playing)
    sc.share_icon(x + 52 + sp + 15, cy + 1, 28)
    sc.photo_icon(x + 52 + sp + 30 + sp + 15, cy, 28)
    sc.home_indicator()
    return sc.im


# ---------------------------------------------------------------- frames

def phone_frame(W, H, scale, idx, screen, ipad):
    c = peach_bg(W, H)
    y = draw_caption(c, SHOTS[idx][1], SHOTS[idx][2], scale)
    top = y + round(70 * scale)
    avail = H - top - round(110 * scale)
    bez = 0.036 if not ipad else 0.03
    sw = int(avail / (screen.height / screen.width + 2 * bez))
    sw = min(sw, W - round(160 * scale))
    device(c, screen, W / 2, top, sw, radius=0.14 if not ipad else 0.045, bezel=bez)
    return c


def export_frame(W, H, scale, idx, ipad):
    c = peach_bg(W, H)
    y = draw_caption(c, SHOTS[idx][1], SHOTS[idx][2], scale)
    scr = detail_screen(ipad, "page")
    k = 3 if not ipad else 2.4
    # crop: the page area + the play/share/photo row (omr-style card)
    y0 = round(((62 if not ipad else 34) + 52 + 38 + 34 + 40) * k)
    crop_h = round((322 if not ipad else 476) * k)
    page = scr.crop((0, y0, scr.width, y0 + crop_h))
    bar = scr.crop((0, round(scr.height - 130 * k), scr.width, round(scr.height - 20 * k)))
    panel = Image.new("RGB", (scr.width, page.height + bar.height), PAPER)
    panel.paste(page, (0, 0)); panel.paste(bar, (0, page.height))
    # ring the share button (the one being tapped)
    pd = ImageDraw.Draw(panel)
    cx = scr.width / 2 - (52 + 32 + 30 + 32 + 30) * k / 2 + (52 + 32 + 15) * k
    cyy = page.height + (130 - 34 - 14 - 26) * k
    r = 30 * k
    pd.ellipse((cx - r, cyy - r, cx + r, cyy + r), outline=TEAL, width=round(3 * k))
    labels = ["MIDI", "MusicXML", "PDF", "MP3", "PNG photo"]
    probe = Image.new("RGB", (W, H))
    gh = chip_grid(probe, labels, 0, scale)
    gap = round(140 * scale)
    width = min(W - round(100 * scale), round(1220 * scale))
    room = H - y - round(60 * scale) - gap - gh - round(120 * scale)
    width = int(min(width, room * panel.width / panel.height))
    ph = panel.height * width / panel.width
    top = y + max(round(60 * scale), (H - y - ph - gap - gh) * 0.42)
    _, y1 = card(c, panel, W / 2, top + ph / 2, width, round(70 * scale))
    chip_grid(c, labels, y1 + gap, scale, highlight="MIDI")
    return c


def build(prefix, W, H):
    ipad = prefix == "ipad-13"
    scale = W / 1320 if not ipad else 1.4
    return [
        phone_frame(W, H, scale, 0, library_screen(ipad), ipad),
        phone_frame(W, H, scale, 1, detail_screen(ipad, "page"), ipad),
        phone_frame(W, H, scale, 2, detail_screen(ipad, "page", playing=True), ipad),
        phone_frame(W, H, scale, 3, detail_screen(ipad, "roll", playing=True), ipad),
        export_frame(W, H, scale, 4, ipad),
    ]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for f in OUT.glob("*.png"):
        if f.name.startswith(("iphone-69-", "ipad-13-")):
            f.unlink()
    for prefix, (W, H) in SIZES.items():
        for (name, _, _), img in zip(SHOTS, build(prefix, W, H)):
            img = img.convert("RGB")
            assert img.size == (W, H), img.size
            dst = OUT / f"{prefix}-{name}.png"
            img.save(dst, optimize=True)
            print(dst.relative_to(ROOT), img.size, img.mode)


if __name__ == "__main__":
    main()
