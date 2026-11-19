"""Original mascot: a little retro PC with a CRT face (drawn for these demos)."""
import numpy as np
from font5x7 import sprite
C = {'k': 0, 'b': 1, 'g': 7, 'd': 8, 'w': 15, 'G': 10, 'R': 12, 'r': 4, 'y': 14, 'c': 3, 'C': 11}
BODY = [
 ".dddddddddddddddddd.",
 "dggggggggggggggggggd",
 "dggkkkkkkkkkkkkkkggd",
 "dggkkkkkkkkkkkkkkggd",
 "dggkkkkkkkkkkkkkkggd",
 "dggkkkkkkkkkkkkkkggd",
 "dggkkkkkkkkkkkkkkggd",
 "dggkkkkkkkkkkkkkkggd",
 "dggkkkkkkkkkkkkkkggd",
 "dggkkkkkkkkkkkkkkggd",
 "dggggggggggggggggRgd",
 ".dddddddddddddddddd.",
 "......dggggggd......",
 "..dddddddddddddddd..",
 "..dwwwwwwwwwwwwwwd..",
 "..dwwddddddddwwGwd..",
 "..dwwwwwwwwwwwwwwd..",
 "..dddddddddddddddd..",
]
LEGS = [
 [".....dd......dd.....",
  ".....dd......dd.....",
  "....RRR.....RRR....."],
 ["....dd........dd....",
  "...dd..........dd...",
  "..RRR..........RRR.."],
 [".....dd......dd.....",
  "......dd....dd......",
  ".....RRR...RRR......"],
]
ARMS = {  # (row, col) pixels, dark gray
 'down': [(14, 1), (15, 0), (16, 0), (14, 18), (15, 19), (16, 19)],
 'wave': [(14, 1), (15, 0), (16, 0), (13, 18), (12, 19), (11, 19), (10, 19)],
 'up':   [(13, 1), (12, 0), (11, 0), (13, 18), (12, 19), (11, 19)],
}
FACES = {
 'open':  ["..............", "...GG....GG...", "...GG....GG...", "..............",
           "..............", "..G........G..", "...GGGGGGGG...", ".............."],
 'blink': ["..............", "..............", "...GG....GG...", "..............",
           "..............", "..G........G..", "...GGGGGGGG...", ".............."],
 'happy': ["..............", "...G.G..G.G...", "..G...GG...G..", "..............",
           "...GGGGGGGG...", "...G......G...", "....GGGGGG....", ".............."],
 'oh':    ["..............", "...GG....GG...", "...GG....GG...", "..............",
           "......GG......", ".....G..G.....", "......GG......", ".............."],
}
W, H = 20, 21

def make(face='open', legs=0, arms='down', eq=None):
    s = -np.ones((H + 1, W), int)   # +1 spare row above for arms 'up'
    s[1:1 + len(BODY)] = sprite(BODY, C)
    s[1 + 18:1 + 21] = sprite(LEGS[legs], C)
    for r, c in ARMS[arms]: s[1 + r, c] = 8
    if eq is None:
        f = sprite(FACES[face], C); m = f >= 0
        s[3:11, 3:17][m] = f[m]
    else:   # equaliser: 4 bars, heights 0..7
        cols = [10, 14, 12, 11]
        for i, h in enumerate(eq):
            h = int(max(0, min(7, h)))
            if h: s[3 + 8 - h:3 + 8, 4 + i * 3:6 + i * 3] = cols[i]
    return s
