#!/usr/bin/env python3
"""DEMO5: original demo for XDC-Plus screen mode 5 (CGA 160x100x16 RGBI, 30 fps).
All pictures and music are generated here; the only outside asset is the
StairwayToRetro logo text, redrawn with our own 5x7 font."""
import sys, os
from pathlib import Path
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from font5x7 import text_mask, blit_mask, blit_sprite
import mascot, music
import palette

W, H, FPS, SR = 160, 100, 30, 11040
DUR = 60.0; N = int(DUR * FPS); SPF = SR // FPS
HERE = Path(__file__).resolve().parent
OUT = Path(os.environ.get("OUT", HERE / "build" / "DEMO5")); NAME = "DEMO5"
M0 = 4.0          # music start (s); 120 bpm, one bar = 2 s
rng = np.random.default_rng(5)

# ---------------------------------------------------------------- timeline
PROMPT = "XDP_PLAY DEMO5"
TYPE1 = [0.6 + i * 0.13 for i in range(len(PROMPT))]; ENTER1 = 2.75
LOGO = [(2, 0, "C:\\THE"), (2, 2, "\\STAIRWAY"), (2, 3, "\\TO"), (2, 4, "\\RETRO>")]
LOGO_T0, LOGO_DT = 4.3, 0.22
logo_chars = []   # (time, line, col)
k = 0
for li, (_, ind, s) in enumerate(LOGO):
    for ci, ch in enumerate(s):
        logo_chars.append((LOGO_T0 + k * LOGO_DT + li * 0.3, li, ci)); k += 1
SCROLL = ("     STAIRWAY TO RETRO PRESENTS ... XDC-PLUS ON THE ATARI PC2 ... "
          "CGA 160X100 IN 16 COLOURS AT 30 FPS ... ALL PIXELS AND MUSIC MADE FOR THIS DEMO ... "
          "BASED ON XDC BY TRIXTER - HORNET ... GREETINGS TO ALL IBM PC, TANDY AND DOS FANS ... "
          "KEEP THE OLD IRON ALIVE!            ")

# ---------------------------------------------------------------- music
def make_music():
    s = music.Song(120, DUR); b = s.beat; bar = 4 * b
    for t in TYPE1 + [ENTER1]: s.click(t, 0.5 if t == ENTER1 else 0.35)
    for t, _, _ in logo_chars: s.click(t, 0.22)
    prog_A = [('A', ['A4', 'C5', 'E5']), ('F', ['F4', 'A4', 'C5']), ('C', ['C4', 'E4', 'G4']), ('G', ['G4', 'B4', 'D5'])]
    prog_B = [('D', ['D4', 'F4', 'A4']), ('A', ['A4', 'C5', 'E5']), ('F', ['F4', 'A4', 'C5']), ('E', ['E4', 'G#4', 'B4'])]
    leadA1 = ["E5 - E5 D5 C5 - A4 -", "C5 - D5 - E5 - F5 E5", "G5 - E5 - C5 - D5 E5", "D5 - - - B4 - G4 -"]
    leadA2 = ["E5 - E5 D5 C5 - A4 -", "C5 - D5 - E5 - F5 G5", "A5 - G5 - E5 - C5 D5", "E5 - - - D5 - - -"]
    leadB = ["F5 - E5 - D5 - A4 -", "C5 - B4 - A4 - E4 -", "F4 - A4 - C5 - F5 -", "E5 - - - G#4 - B4 -",
             "D5 - F5 - A5 - G5 F5", "E5 - C5 - A4 - C5 E5", "F5 - E5 - D5 - C5 B4", "B4 - - - G#4 - E4 -"]
    plan = []   # per bar: (chord, section)
    for i in range(4): plan.append((prog_A[i], 'intro'))
    for i in range(8): plan.append((prog_A[i % 4], 'A'))
    for i in range(8): plan.append((prog_B[i % 4], 'B'))
    for i in range(6): plan.append((prog_A[i % 4], 'A3'))
    for k, ((root, tri), sec) in enumerate(plan):
        t = M0 + k * bar
        bnote = {'A': 'A2', 'F': 'F2', 'C': 'C3', 'G': 'G2', 'D': 'D3', 'E': 'E2'}[root]
        bm = music.midi(bnote)
        for e in range(8):   # bass eighths, octave bounce
            s.bass(t + e * b / 2, b / 2 * 0.9, bm + (12 if e % 2 else 0), 0.42 if sec != 'intro' else 0.36)
        if sec in ('intro', 'B') or (sec == 'A3' and k % 2):
            s.arp(t, bar * 0.98, tri + [music.midi(tri[0]) + 12], vol=0.11)
        if sec != 'intro':
            for q in range(4):
                if q in (0, 2): s.kick(t + q * b)
                else: s.snare(t + q * b)
            if sec in ('A3', 'B') : s.kick(t + 2.5 * b, 0.6)
            for e in range(8): s.hat(t + e * b / 2, 0.12 if e % 2 else 0.08, open_=(e == 7))
        elif k >= 2:
            for e in range(8): s.hat(t + e * b / 2, 0.06)
    s.melody(M0 + 4 * bar, leadA1, vol=0.30, duty=0.5)
    s.melody(M0 + 8 * bar, leadA2, vol=0.30, duty=0.5)
    s.melody(M0 + 12 * bar, leadB, vol=0.28, duty=0.25, vib=0.008)
    s.melody(M0 + 20 * bar, leadA1, vol=0.30, duty=0.125)
    s.melody(M0 + 24 * bar, leadA2[:2], vol=0.30, duty=0.125)
    # ending: big A minor hit at 56 s, rings out
    te = M0 + 26 * bar
    s.kick(te, 0.9); s.hat(te, 0.15, open_=True)
    s.bass(te, 3.0, 'A2', 0.45)
    for nte in ['A4', 'C5', 'E5']: s.lead(te, 3.2, nte, vol=0.16, duty=0.5, d=1.2, s=0.4)
    s.lead(te, 3.2, 'A5', vol=0.18, duty=0.125, d=1.2, s=0.4)
    x = s.mix(end_at=59.6, fade_out=2.5)
    return x, s

# ---------------------------------------------------------------- pictures
def stars():
    pts = []
    while len(pts) < 26:
        x, y = int(rng.integers(2, 158)), int(rng.integers(14, 60))
        if 118 < x < 152 and 14 < y < 36: continue   # keep moon clear
        pts.append((x, y, int(rng.choice([15, 15, 7, 14])), float(rng.uniform(13, 15.5))))
    return pts
STARS = stars()

def mountains():
    m = np.zeros((H, W), bool); h = 0.0
    ys = 72 - 7 * np.sin(np.arange(W) / 13.0) - 4 * np.sin(np.arange(W) / 5.3 + 1) - 3 * np.abs(np.sin(np.arange(W) / 23.0))
    for x in range(W): m[int(ys[x]):84, x] = True
    return m
MOUNT = mountains()

def background(t):
    """static scenery once built (stars twinkle a little)"""
    img = np.full((H, W), 1, np.uint8)
    # moon
    yy, xx = np.mgrid[:H, :W]
    moon = (xx - 135) ** 2 + ((yy - 25) * 1.2) ** 2 < 49
    bite = (xx - 132) ** 2 + ((yy - 23) * 1.2) ** 2 < 36
    img[moon & ~bite] = 14
    for i, (x, y, c, t0) in enumerate(STARS):
        if t < t0: continue
        tw = (int(t * 2.0) + i * 7) % 23 == 0
        img[y, x] = 8 if tw else c
    # ground grows from the bottom between 12.5 and 14.0 s
    top = 100 - int(np.clip((t - 12.5) / 1.5, 0, 1) * 100)
    g = np.zeros((H, W), np.uint8); g[:] = 255
    g[MOUNT] = 9
    g[84:] = 2
    g[84, ::3] = 10; g[85, 1::5] = 10
    g[90:95] = 6; g[90, ::4] = 14 * 0 + 6
    g[96:, 2::7] = 10
    sel = (g != 255); sel[:top] = False
    img[sel] = g[sel]
    return img

def scroller(img, t):
    if t < 13.0 or t >= 56.0: return
    img[0:11] = 0
    m = text_mask(SCROLL)
    off = int((t - 13.0) * FPS)
    x = W - off
    blit_mask(img, m, x, 2, 14)
    # copper line under the band
    cols = [4, 12, 14, 15, 11, 9, 1, 9, 11, 15, 14, 12]
    ph = int(t * FPS)
    idx = ((np.arange(W) + ph) // 4) % len(cols)
    img[11] = np.array(cols)[idx]

def bubble(img, text, x, y, tx):
    m = text_mask(text)
    w = m.shape[1] + 3; h = 11
    img[y:y + h, x:x + w] = 15
    img[y, x:x + w] = 0; img[y + h - 1, x:x + w] = 0; img[y:y + h, x] = 0; img[y:y + h, x + w - 1] = 0
    img[y, x] = 1; img[y, x + w - 1] = 1; img[y + h - 1, x] = 1; img[y + h - 1, x + w - 1] = 1
    blit_mask(img, m, x + 2, y + 2, 0)
    # tail towards mascot
    for i in range(3): img[y + h - 1 + i, tx + i:tx + 3] = 15; img[y + h - 1 + i, tx + 3] = 0
    img[y + h + 2, tx + 3] = 0

NOTE_SPR = np.array([[-1, -1, 14, 14], [-1, -1, 14, -1], [-1, -1, 14, -1], [14, 14, 14, -1], [14, 14, -1, -1]])

def eq_levels(xs, t):
    """four bar heights from the actual mix tracks around time t"""
    out = []
    for name in ('bass', 'lead', 'drums', 'arp'):
        b = xs.tracks.get(name)
        i = int(t * SR); seg = b[max(0, i - 368):i + 368] if b is not None else np.zeros(1)
        out.append(np.sqrt((seg ** 2).mean()) * 22)
    return out

def frame(f, song):
    t = f / FPS
    beat = 0.5; bt = (t - M0) / beat
    if t < 3.0:                                    # DOS prompt
        img = np.zeros((H, W), np.uint8)
        typed = sum(1 for x in TYPE1 if x <= t)
        s = "C:\\>" + PROMPT[:typed]
        blit_mask(img, text_mask(s), 2, 3, 7)
        if int(t * 3.75) % 2 == 0 and t < ENTER1:
            img[10, 2 + 6 * len(s):7 + 6 * len(s)] = 7
        return img
    if t < 4.0:                                    # venetian blind wipe to blue
        img = np.zeros((H, W), np.uint8)
        blit_mask(img, text_mask("C:\\>" + PROMPT), 2, 3, 7)
        p = (t - 3.0) / 1.0
        for y in range(H):
            if (y % 10) < p * 10.5: img[y] = 1
        return img
    img = background(t) if t >= 12.5 else np.full((H, W), 1, np.uint8)
    if t < 13.2:                                   # logo typed letter by letter
        lm = np.zeros((H, W), bool); last = None
        for (tc, li, ci) in logo_chars:
            if tc <= t:
                _, ind, s = LOGO[li]
                g = text_mask(s[ci], scale=2)
                blit_mask(lm, g, 8 + (ind + ci) * 12, 13 + li * 20, True); last = (li, ci)
        done = t >= logo_chars[-1][0]
        if done:   # blinking bar cursor like the logo
            if int(t * 3.75) % 2 == 0: lm[13 + 3 * 20:13 + 3 * 20 + 14, 8 + (4 + 7) * 12 + 2:8 + (4 + 7) * 12 + 4] = True
        if t >= 12.0:                              # dissolve away
            p = (t - 12.0) / 1.0
            r = np.random.default_rng(77).random((H, W))
            lm &= r > p
        img[lm] = 15
    scroller(img, t)
    # ---- mascot
    if 14.0 <= t < 58.0:
        face, legs, arms, eq, dy = 'open', 0, 'down', None, 0
        if t < 20.0:
            x = int(-22 + (t - 14.0) / 6.0 * 92); legs = 1 + (int(t * 4) % 2)
        elif t < 56.0:
            x = 70
            ph = bt % 1.0
            if 24.0 <= t < 28.0 or 44.0 <= t < 56.0:
                dy = -3 if ph < 0.3 else 0
            if 28.0 <= t < 44.0:
                eq = eq_levels(song, t); dy = -2 if ph < 0.2 else 0
            if t < 28.0:
                face = 'blink' if (t % 3.0) < 0.12 else ('happy' if t >= 24.0 else 'open')
                if 21.0 <= t < 24.0: arms = 'wave' if int(t * 4) % 2 else 'down'
            if t >= 44.0:
                face = 'happy'; arms = 'up' if (44.0 <= t < 48.0 and ph < 0.5) else ('wave' if int(t * 4) % 2 and t >= 50 else 'down')
        else:
            x = int(70 + (t - 56.0) / 2.0 * 95); legs = 1 + (int(t * 4) % 2); face = 'happy'
        spr = mascot.make(face, legs, arms, eq)
        blit_sprite(img, spr, x, 71 + dy)
        # floating music notes during section B
        if 28.0 <= t < 44.0:
            for k2 in range(3):
                age = (bt - k2 * 1.33) % 4.0
                if age < 3.0:
                    nx = 70 + 24 + int(4 * np.sin(age * 2 + k2)) + k2 * 8
                    ny = 70 - int(age * 12)
                    blit_sprite(img, NOTE_SPR, nx, ny)
        # bubbles
        if 21.0 <= t < 26.5: bubble(img, "HELLO RETRO FANS!", 34, 52, 74)
        if 36.0 <= t < 41.5: bubble(img, "XDC-PLUS ON AN 8088!", 26, 52, 74)
        if 50.0 <= t < 55.5: bubble(img, "THANKS FOR WATCHING!", 26, 52, 74)
    # shooting stars
    for ts in (30.0, 36.5, 42.0, 47.0):
        if ts <= t < ts + 0.8:
            k3 = int((t - ts) * FPS)
            hx = 10 + int(ts * 7) % 60 + k3 * 3; hy = 16 + k3
            for j, c in enumerate([15, 7, 8, 8]):
                xx, yy = hx - 3 * j, hy - j
                if 0 <= xx < W and 12 <= yy < 60: img[yy, xx] = c
    # ending: dissolve to black then DOS prompt
    if t >= 57.0:
        p = min(1.0, (t - 57.0) / 2.3)
        r = np.random.default_rng(99).random((H, W))
        img[r < p] = 0
        if t >= 59.3:
            img[:] = 0
            blit_mask(img, text_mask("C:\\>"), 2, 3, 7)
            if int(t * 3.75) % 2 == 0: img[10, 26:31] = 7
    return img

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    x, song = make_music()
    pcm = music.to_u8(x)[:N * SPF]
    (OUT / f"{NAME}.WAV").write_bytes(music.wav_bytes(pcm))
    fr = np.stack([frame(f, song) for f in range(N)])
    names = []
    for i, im in enumerate(fr):
        nm = f"F{i:04d}.BMP"; palette.write_bmp(OUT / nm, im); names.append(nm)
    lines = [f"sourcefps={FPS}", "screenmode=5", "debug=1", f"waveinput={NAME}.WAV"] + names
    (OUT / f"{NAME}.SCR").write_bytes(("\r\n".join(lines) + "\r\n").encode("ascii"))
    ch = (fr[1:] != fr[:-1]).mean((1, 2))
    print(N, "frames,", len(pcm), "audio bytes; changed px/frame mean %.4f max %.3f p95 %.3f" % (ch.mean(), ch.max(), np.percentile(ch, 95)))
    worst = np.argsort(-ch)[:8]; print("worst frames", [(int(i) + 1, round(float(ch[i]), 3)) for i in worst])

main()
