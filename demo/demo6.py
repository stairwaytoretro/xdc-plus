#!/usr/bin/env python3
"""DEMO6: original demo for XDC-Plus screen mode 6 (EGA 320x200x16, 15 fps).
Pictures and music generated here. Outside asset: the StairwayToRetro logo
(the author's own X profile picture, @StairwayToRetro), scaled to EGA pixels."""
import sys, os
from pathlib import Path
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from font5x7 import text_mask, blit_mask, blit_sprite
import mascot, music, plan6

W, H, FPS, SR = 320, 200, 15, 11040
DUR = 60.0; N = int(DUR * FPS); SPF = SR // FPS
HERE = Path(__file__).resolve().parent
OUT = Path(os.environ.get("OUT", HERE / "build" / "DEMO6")); NAME = "DEMO6"
BPM = 112.5; BEAT = 60 / BPM; BAR = 4 * BEAT          # bar = 32 frames
def tb(bar): return bar * BAR
ASSET = HERE / "assets" / "logo_400.png"   # @StairwayToRetro profile picture
_L = Image.open(ASSET).convert("L").crop((44, 98, 352, 308))
LOGO_BIG = np.array(_L.resize((206, 118), Image.BOX)) > 110   # 1.2 tall pixels -> keep proportions
LOGO_SM = np.array(_L.resize((154, 88), Image.BOX)) > 110
rng = np.random.default_rng(6)

# ------------------------------------------------------------------ music
def make_music():
    s = music.Song(BPM, DUR); b = BEAT; bar = BAR
    chords = {'Dm': ('D3', ['D4', 'F4', 'A4']), 'Bb': ('A#2', ['A#3', 'D4', 'F4']), 'C': ('C3', ['C4', 'E4', 'G4']),
              'A': ('A2', ['A3', 'C#4', 'E4']), 'Gm': ('G2', ['G3', 'A#3', 'D4']), 'F': ('F2', ['F3', 'A3', 'C4'])}
    pa = ['Dm', 'Bb', 'C', 'A']; pb = ['Gm', 'Dm', 'Bb', 'A', 'Gm', 'C', 'F', 'A']
    A1 = ["D5 - F5 - A5 - G5 F5", "F5 - D5 - A#4 - C5 D5", "E5 - G5 - E5 - C5 -", "C#5 - - - E5 - A4 -"]
    A2 = ["A5 - G5 F5 E5 - D5 -", "F5 - - - D5 - F5 -", "G5 - - - E5 - C5 E5", "A5 - - - - - . ."]
    B = ["G5 - A#5 - A5 - G5 -", "F5 - A5 - D5 - - -", "D5 - F5 - A#5 - A5 G5", "E5 - C#5 - A4 - - -",
         "A#4 - D5 - G5 - F5 E5", "E5 - G5 - C6 - A#5 -", "A5 - - - F5 - C5 -", "C#5 - E5 - A5 - - -"]
    plan = [('Dm', 'intro'), ('A', 'intro')] + [(pa[i % 4], 'A') for i in range(8)] + \
           [(pb[i], 'B') for i in range(8)] + [(pa[i % 4], 'A2') for i in range(8)]
    for k, (ch, sec) in enumerate(plan):
        t = tb(k); root, tri = chords[ch]; rm = music.midi(root)
        if sec == 'intro':
            s.bass(t, bar * 0.95, rm, 0.35)
            s.arp(t, bar * 0.98, tri + [music.midi(tri[0]) + 12, music.midi(tri[1]) + 12], vol=0.12, step=1 / 25)
            continue
        for e in range(16):   # sixteenth bass with octave hop
            pat = [0, 0, 12, 0, 0, 12, 0, 12, 0, 0, 12, 0, 0, 12, 7, 12]
            s.bass(t + e * b / 4, b / 4 * 0.85, rm + pat[e], 0.38)
        s.arp(t, bar * 0.98, tri + [music.midi(tri[0]) + 12], vol=0.09 if sec != 'B' else 0.11, step=1 / 25)
        for q in range(4):
            s.kick(t + q * b, 0.75) if q in (0, 2) else s.snare(t + q * b, 0.42)
        s.kick(t + 3.5 * b, 0.5)
        for e in range(8): s.hat(t + e * b / 2, 0.11 if e % 2 else 0.07)
        if k % 4 == 3: s.snare(t + 3.75 * b, 0.25)
    # leads (with echo track)
    def lead(t0, bars, **kw):
        s.melody(t0, bars, **kw)
        kw2 = dict(kw); kw2['vol'] = kw.get('vol', 0.3) * 0.35; kw2['name'] = 'echo'
        s.melody(t0 + 0.75 * b, bars, **kw2)
    lead(tb(2), A1, vol=0.28, duty=0.25, vib=0.007)
    lead(tb(6), A2, vol=0.28, duty=0.25, vib=0.007)
    lead(tb(10), B, vol=0.26, duty=0.5, vib=0.009)
    lead(tb(18), A1, vol=0.28, duty=0.125, vib=0.007)
    lead(tb(22), A2, vol=0.28, duty=0.125, vib=0.007)
    # harmony a third below in the last A
    s.melody(tb(18), ["A#4 - D5 - F5 - E5 D5", "D5 - A#4 - F4 - A4 A#4", "C5 - E5 - C5 - G4 -", "A4 - - - C#5 - E4 -"],
             vol=0.13, duty=0.5, name='harm')
    te = tb(26)
    s.kick(te, 0.9); s.hat(te, 0.15, open_=True)
    s.bass(te, 3.5, 'D2', 0.45)
    for nte in ['D4', 'F4', 'A4']: s.lead(te, 3.8, nte, vol=0.15, duty=0.5, d=1.4, s=0.35)
    s.lead(te, 3.8, 'D5', vol=0.17, duty=0.25, d=1.4, s=0.35, vib=0.01)
    return s.mix(end_at=59.7, fade_out=2.6, fade_in=0.05), s

# ------------------------------------------------------------------ scenery
HZ = 138                                   # horizon row
STARS = [(int(rng.integers(0, W)), int(rng.integers(0, HZ)), int(rng.choice([15, 7, 8, 7, 14]))) for _ in range(70)]

def ground():
    g = np.zeros((H - HZ, W), np.uint8)
    for k in range(16):                    # perspective grid rows
        y = int(round(61 * 0.8 ** k))
        g[y] = 13 if y > 30 else 5
    for k in range(-14, 15):
        x0 = 160 + k * 6; x1 = 160 + k * 60
        for y in range(H - HZ):
            x = int(round(x0 + (x1 - x0) * y / (H - HZ - 1)))
            if 0 <= x < W: g[y, x] = 13 if y > 30 else 5
    g[0] = 13
    return g
GROUND = ground()

def sun(img, rise):
    """striped sun sitting on the horizon; rise 0..1"""
    cy = HZ + 28 - int(rise * 28); r = 26
    yy, xx = np.mgrid[:HZ, :W]
    disc = (xx - 250) ** 2 + ((yy - cy) * 1.2) ** 2 < r * r
    band = ((cy - yy) % 6 < 2) & (yy > cy - 14)
    col = np.where(yy < cy - 12, 14, np.where(yy < cy - 4, 12, 13)).astype(np.uint8)
    m = disc & ~band
    img[:HZ][m] = col[m]

def box(img, x0, y0, x1, y1, c):
    img[y0, x0:x1 + 1] = c; img[y1, x0:x1 + 1] = c; img[y0:y1 + 1, x0] = c; img[y0:y1 + 1, x1] = c

def line(img, x0, y0, x1, y1, c, clip):
    n = int(max(abs(x1 - x0), abs(y1 - y0))) + 1
    xs = np.round(np.linspace(x0, x1, n)).astype(int); ys = np.round(np.linspace(y0, y1, n)).astype(int)
    cx0, cy0, cx1, cy1 = clip
    m = (xs >= cx0) & (xs <= cx1) & (ys >= cy0) & (ys <= cy1)
    img[ys[m], xs[m]] = c

WIN = (186, 8, 311, 99)                     # 3D window (inclusive)
PAN = (6, 6, 171, 101)                      # logo panel
CUBE = np.array([[x, y, z] for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)], float)
EDGES = [(a, b) for a in range(8) for b in range(a + 1, 8) if np.sum(CUBE[a] != CUBE[b]) == 1]

def cube(img, t, col=11, size=30):
    ax, ay = t * 0.9, t * 1.3
    R1 = np.array([[1, 0, 0], [0, np.cos(ax), -np.sin(ax)], [0, np.sin(ax), np.cos(ax)]])
    R2 = np.array([[np.cos(ay), 0, np.sin(ay)], [0, 1, 0], [-np.sin(ay), 0, np.cos(ay)]])
    P = CUBE @ R1.T @ R2.T
    cx, cy = (WIN[0] + WIN[2]) / 2, (WIN[1] + WIN[3]) / 2
    z = P[:, 2] + 4.0
    sx = cx + P[:, 0] * size * 4 / z; sy = cy + P[:, 1] * size * 4 / z / 1.2
    clip = (WIN[0] + 1, WIN[1] + 1, WIN[2] - 1, WIN[3] - 1)
    order = sorted(EDGES, key=lambda e: -(P[e[0], 2] + P[e[1], 2]))
    for a, b in order:
        back = (P[a, 2] + P[b, 2]) > 0.6
        line(img, sx[a], sy[a], sx[b], sy[b], 9 if back else col, clip)

PL_COLS = np.array([4, 6, 12, 14, 12, 6])
def plasma(img, t):
    x0, y0, w, h = 200, 22, 96, 64
    yy, xx = np.mgrid[0:h:4, 0:w:4] / 4.0
    f = int(round(t * FPS))                # interlaced: half the block rows per frame
    tt = np.where((yy.astype(int) + f) % 2 == 0, f, f - 1) / FPS
    v = (np.sin(xx / 3.0 + tt * 1.7) + np.sin(yy / 2.3 - tt * 1.1) + np.sin((xx + yy) / 4.0 + tt * 0.8)
         + np.sin(np.hypot(xx - 12 + 4 * np.sin(tt * 0.5), yy - 8) / 2.0))
    k = ((v + 4) / 8 * len(PL_COLS) * 1.5).astype(int) % len(PL_COLS)
    img[y0:y0 + h, x0:x0 + w] = np.kron(PL_COLS[k], np.ones((4, 4), int))

SF = np.random.default_rng(3).uniform(-1, 1, (60, 3))
def starfield(img, t):
    cx, cy = (WIN[0] + WIN[2]) / 2, (WIN[1] + WIN[3]) / 2
    for i, (x, y, z0) in enumerate(SF):
        z = (z0 + 1) / 2 - (t * 0.35) % 1.0
        z = z % 1.0 + 0.05
        sx = int(cx + x * 25 / z); sy = int(cy + y * 18 / z)
        if WIN[0] < sx < WIN[2] and WIN[1] < sy < WIN[3]:
            img[sy, sx] = 15 if z < 0.35 else (9 if z < 0.7 else 3)

SCROLL = ("STAIRWAY TO RETRO PRESENTS XDC-PLUS ... EGA 320X200 IN 16 COLOURS ON AN 8 MHZ ATARI PC2 ... "
          "ALL PIXELS AND CHIP MUSIC MADE FOR THIS DEMO ... BASED ON XDC BY TRIXTER - HORNET ... "
          "HELLO TO ALL DOS FANS!       ")
SC_Y = 112; SC_X0, SC_X1 = 40, 280; SC_COLS = [12, 12, 6, 6, 10, 10, 10, 3, 3, 9, 9, 9, 5, 5]; SC_PH = 0.0
SCROLL_MASK = text_mask(SCROLL, scale=2)
def scroller(img, t, t0, t1):
    if not (t0 <= t < t1): return
    off = int((t - t0) * FPS * 3)
    m = SCROLL_MASK
    for x in range(SC_X0, SC_X1, 2):       # 2-pixel columns follow a sine
        sxm = x - SC_X1 + off
        if sxm < 0 or sxm + 2 > m.shape[1]: continue
        dy = int(round(7 * np.sin(x / 26.0 + t * SC_PH)))
        col = m[:, sxm:sxm + 2]
        for r in range(14):
            yy = SC_Y + dy + r
            img[yy, x:x + 2][col[r]] = SC_COLS[(yy - SC_Y + 7) * len(SC_COLS) // 28]

def big_mascot(img, x, y, face='open', legs=0, arms='down', eq=None):
    s = mascot.make(face, legs, arms, eq)
    s2 = np.kron(s, np.ones((2, 2), int))
    # glass shine on the CRT
    s2[6:8, 8:12] = np.where(s2[6:8, 8:12] == 0, 8, s2[6:8, 8:12])
    blit_sprite(img, s2, x, y)

def bubble(img, text, x, y, tx):
    m = text_mask(text); w = m.shape[1] + 5; h = 13
    img[y:y + h, x:x + w] = 15; box(img, x, y, x + w - 1, y + h - 1, 0)
    blit_mask(img, m, x + 3, y + 3, 1)
    for i in range(4): img[y + h - 1 + i, tx + i:tx + 4] = 15; img[y + h - 1 + i, tx + 4] = 0

NOTE_SPR = np.kron(np.array([[-1, -1, 14, 14], [-1, -1, 14, -1], [-1, -1, 14, -1], [14, 14, 14, -1], [14, 14, -1, -1]]), np.ones((2, 2), int))

def eq_levels(song, t):
    out = []
    for name in ('bass', 'lead', 'drums', 'arp'):
        b = song.tracks.get(name); i = int(t * SR)
        seg = b[max(0, i - 736):i + 736] if b is not None else np.zeros(1)
        out.append(np.sqrt((seg ** 2).mean()) * 22)
    return out

def frame(f, song):
    t = f / FPS; img = np.zeros((H, W), np.uint8)
    beat = (t / BEAT); ph = beat % 1.0
    T_MAIN = tb(2)                          # 4.27 s
    if t < T_MAIN + 0.6:
        # intro: big blue panel opens from the centre line, logo revealed stair by stair
        px0, py0, px1, py1 = 45, 33, 274, 166
        if t < T_MAIN:
            o = min(1.0, t / 0.9); cy = (py0 + py1) // 2; hh = int((py1 - py0) / 2 * o)
            if o > 0: img[cy - hh:cy + hh + 1, px0:px1 + 1] = 1
            if t >= 1.0:
                p = min(1.0, (t - 1.0) / 2.0)
                yy, xx = np.mgrid[:118, :206]
                vis = (xx + yy * 0.7) < p * 290
                m = LOGO_BIG & vis
                img[41:41 + 118, 57:57 + 206][m] = 15
                cur = int(t * 3.75) % 2 == 0
                if p >= 1 and not cur: img[41 + 92:41 + 118, 57 + 196:57 + 206] &= 0; img[41:41 + 118, 57:57 + 206][LOGO_BIG & (np.mgrid[:118, :206][1] < 196)] = 15
        else:
            # staircase wipe to black (bottom-right stairs first)
            p = (t - T_MAIN) / 0.6
            img[py0:py1 + 1, px0:px1 + 1] = 1
            img[41:41 + 118, 57:57 + 206][LOGO_BIG] = 15
            yy, xx = np.mgrid[:H, :W]
            stair = ((xx // 32) + (yy // 25)) < p * 18
            img[stair] = 0
        return img
    tm = t - T_MAIN - 0.6                   # main scene clock
    # stars
    for i, (x, y, c) in enumerate(STARS):
        if tm * 40 > i:
            img[y, x] = 8 if (int(t * 3) + i * 5) % 31 == 0 else c
    # sun + ground
    sun(img, min(1.0, tm / 3.0))
    rows = int(min(1.0, tm / 1.2) * (H - HZ))
    img[HZ:HZ + rows] = GROUND[:rows]
    # logo panel slides open left to right
    pw = int(min(1.0, max(0.0, (tm - 0.3) / 1.0)) * (PAN[2] - PAN[0]))
    if pw > 0:
        img[PAN[1]:PAN[3] + 1, PAN[0]:PAN[0] + pw + 1] = 1
        lm = np.zeros((H, W), bool); lm[PAN[1] + 4:PAN[1] + 92, PAN[0] + 6:PAN[0] + 160] = LOGO_SM
        lm[:, PAN[0] + pw + 1:] = False
        img[lm] = 15
        if pw >= PAN[2] - PAN[0]:
            box(img, PAN[0], PAN[1], PAN[2], PAN[3], 9)
            if int(t * 3.75) % 2: img[PAN[1] + 70:PAN[1] + 92, PAN[0] + 154:PAN[0] + 160] = 1   # cursor blink
    # 3D window
    wo = min(1.0, max(0.0, (tm - 1.3) / 0.8))
    if wo > 0:
        cy = (WIN[1] + WIN[3]) // 2; hh = int((WIN[3] - WIN[1]) / 2 * wo)
        img[cy - hh:cy + hh + 1, WIN[0]:WIN[2] + 1] = 1
        box(img, WIN[0], cy - hh, WIN[2], cy + hh, 3)
        if wo >= 1:
            box(img, WIN[0], WIN[1], WIN[2], WIN[3], 11)
            if t < tb(10) or tb(26) <= t:
                cube(img, t, size=22)
            elif t < tb(18):
                plasma(img, t)
                box(img, 199, 21, 296, 86, 3)
            else:
                starfield(img, t); cube(img, t, col=11, size=20)
    # sine scroller
    scroller(img, t, tb(3), tb(26) + 0.5)
    # mascot
    mx, my, face, legs, arms, eq = None, 147, 'open', 0, 'down', None
    if tb(4) <= t < tb(6):
        mx = int(-44 + (t - tb(4)) / (2 * BAR) * 184); legs = 1 + int(t * 4) % 2
    elif tb(6) <= t < tb(26):
        mx = 140
        if t < tb(10):
            face = 'blink' if (t % 3.0) < 0.15 else 'open'
            if tb(8) <= t: face = 'happy'; my -= 4 if ph < 0.35 else 0
            if tb(6) + 0.5 <= t < tb(7) + 1.0: arms = 'wave' if int(t * 4) % 2 else 'down'
        elif t < tb(18):
            eq = eq_levels(song, t); my -= 3 if ph < 0.3 else 0
        else:
            face = 'happy'; my -= 5 if ph < 0.35 else 0
            arms = 'up' if (int(beat) % 4 < 2) else 'wave'
    elif tb(26) <= t < tb(26) + 2.0:
        mx = int(140 + (t - tb(26)) / 2.0 * 190); legs = 1 + int(t * 4) % 2; face = 'happy'
    if mx is not None:
        big_mascot(img, mx, my, face, legs, arms, eq)
        if tb(10) <= t < tb(18):
            for k in range(3):
                age = (beat - k * 1.33) % 4.0
                if age < 3.0:
                    blit_sprite(img, NOTE_SPR, mx + 46 + k * 14 + int(6 * np.sin(age * 2 + k)), 150 - int(age * 14))
        if tb(7) <= t < tb(9): bubble(img, "HELLO RETRO FANS!", 60, 132, 150)
        if tb(14) <= t < tb(16): bubble(img, "320X200 ON AN 8088!", 60, 132, 150)
        if tb(22) <= t < tb(25): bubble(img, "THANKS FOR WATCHING!", 56, 132, 150)
    # outro: black bars close in, then a line shrinks to a dot, then the DOS prompt
    TC = tb(26) + 1.6
    if t >= TC:
        p = min(1.0, (t - TC) / 1.4)
        k = int(p * 99)
        img[:k] = 0; img[H - k:] = 0
        if p >= 1.0:
            q = min(1.0, (t - TC - 1.4) / 0.5)
            img[:] = 0
            if q < 1:
                hw = int((1 - q) * 160); img[99:101, 160 - hw:160 + hw + 1] = 15
            if t >= TC + 2.0:
                blit_mask(img, text_mask("C:\\>"), 4, 4, 7)
                if int(t * 3.75) % 2 == 0: img[11, 28:33] = 7
    return img

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    x, song = make_music()
    pcm = music.to_u8(x)[:N * SPF]
    pcm = np.r_[pcm, np.full(N * SPF - len(pcm), 128, np.uint8)]
    fr = np.stack([frame(f, song) for f in range(N)])
    ch = (fr[1:] != fr[:-1]).mean((1, 2))
    print(N, "frames,", len(pcm), "audio bytes; changed px/frame mean %.4f max %.3f p95 %.3f" % (ch.mean(), ch.max(), np.percentile(ch, 95)))
    worst = np.argsort(-ch)[:10]; print("worst frames", [(int(i) + 1, round((int(i) + 1) / FPS, 2), round(float(ch[i]), 3)) for i in worst])
    plan6.build(fr, pcm.tobytes(), OUT, NAME, fps=FPS)

main()
