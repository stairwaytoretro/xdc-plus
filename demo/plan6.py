"""Frame planner for the EGA demo (XDC-Plus screen mode 6, 320x200x16).

XDP_COMP sends the changes between two pictures as code, and the player
must run that code within one frame period. When a frame changes too much
(in DEMO6: the two scene changes at 21.3 s and 38.4 s), we do not hand the compiler the
real picture. We hand it an intermediate picture that fits a per-frame byte
budget, then keep chasing the same target on the next frames:
  - if every change fits the budget, the real target is sent;
  - otherwise, 160x4-pixel cells are copied from the target, the ones with
    the largest perceptual error first (blurred CIELAB difference between
    what is on screen and the target), until the budget is spent.
The cost model is an estimate of the compiler's output, not an exact count.

build() writes F0000.BMP..., DEMO6.WAV and DEMO6.SCR into the output folder."""
import struct
from pathlib import Path
import numpy as np
from scipy.ndimage import uniform_filter
import palette

H, W = 200, 320
CH, CWB = 4, 20                    # cell = 4 rows x 20 bytes (160 pixels)
NR, NC = H // CH, 40 // CWB
PAL_LIN = palette.to_lin(palette.RGBI)
SR = 11040                         # audio sample rate used by the demos

def planes(img):
    """(200, 320) colour indices -> (4, 200, 40) EGA bit-plane bytes"""
    return np.stack([np.packbits(((img >> k) & 1).astype(np.uint8), axis=1) for k in range(4)])

def blur_lab(img):
    lin = PAL_LIN[img]
    lin = uniform_filter(lin, size=(4, 4, 1), mode="nearest")
    return palette.lin_to_lab(lin)

def cell_sum(a):  # (200, 320) -> (NR, NC)
    return a.reshape(NR, CH, NC, CWB * 8).sum((1, 3))

def cell_cost(pa, pb):
    """bytes to move each cell from planes pa to pb, cell by cell: per plane
    row segment, 7 bytes per changed span (gaps <= 2 merged) + span bytes"""
    seg = (pa != pb).reshape(4, H, NC, CWB)
    any_ = seg.any(-1)
    first = np.where(any_, seg.argmax(-1), 0)
    last = np.where(any_, CWB - 1 - seg[..., ::-1].argmax(-1), -1)
    span = np.where(any_, last - first + 1, 0)
    nsp = np.zeros_like(span)                      # number of separate spans
    gap = np.zeros(seg.shape[:-1], int); inside = np.zeros(seg.shape[:-1], bool)
    for k in range(CWB):
        c = seg[..., k]
        nsp += c & (~inside | (gap > 2))
        inside = inside | c
        gap = np.where(c, 0, gap + 1)
    cost = 7 * nsp + span                          # gaps counted as data (upper bound)
    return cost.sum(0).reshape(NR, CH, NC).sum(1)

def span_cost(seg):
    """runs of >= 9 equal bytes become REP STOSB (~9 bytes), the rest is copied"""
    n = len(seg)
    if n < 9: return 7 + n
    b = np.flatnonzero(np.diff(seg) != 0)
    st = np.r_[0, b + 1]; en = np.r_[b + 1, n]
    tot = 0; pend = 0
    for a, z in zip(st, en):
        if z - a >= 9:
            if pend: tot += 7 + pend; pend = 0
            tot += 9
        else:
            pend += z - a
    if pend: tot += 7 + pend
    return tot

def frame_cost(pa, pb):
    """whole-frame estimate, spans merged across cells (closer to the compiler)"""
    tot = 16
    for k in range(4):
        ch = (pa[k] != pb[k]).ravel()
        if not ch.any(): continue
        tot += 4
        i = np.flatnonzero(ch)
        brk = np.flatnonzero(np.diff(i) > 3)
        starts = np.r_[i[0], i[brk + 1]]; ends = np.r_[i[brk], i[-1]]
        v = pb[k].ravel()
        for s, e in zip(starts, ends):
            tot += span_cost(v[s:e + 1])
    return tot

def cellmask(sel):
    return np.repeat(np.repeat(sel, CH, 0), CWB * 8, 1)

def plan(q, budget):
    """q: (N, 200, 320) target pictures -> pictures that fit the budget"""
    S = np.zeros((H, W), np.uint8); PS = planes(S); SL = blur_lab(S)
    states = []; nfull = 0; costs = []; ti = 0
    for t in range(len(q)):
        if (S == q[ti]).all(): ti = t      # keep chasing one target until it is on screen
        T = q[ti]; PT = planes(T)
        if frame_cost(PS, PT) <= budget:
            S = T.copy(); nfull += 1
        else:
            TL = blur_lab(T)
            new = S.copy(); spent = 0
            err = cell_sum(np.sqrt(((blur_lab(new) - TL) ** 2).sum(-1)))
            fcost = cell_cost(planes(new), PT)
            for f in np.argsort(-err, axis=None):   # biggest error first
                r, c = divmod(f, NC)
                if err[r, c] <= 0 or fcost[r, c] == 0: continue
                if spent + fcost[r, c] > budget: continue
                m = cellmask(np.eye(1, NR * NC, f, dtype=bool).reshape(NR, NC))
                new[m] = T[m]; spent += fcost[r, c]
            S = new
        PS2 = planes(S); costs.append(frame_cost(PS, PS2)); PS = PS2; SL = blur_lab(S)
        states.append(S.copy())
    return np.stack(states), nfull, costs

def build(frames, pcm, out, name="DEMO6", fps=15, budget=7800, lead=6):
    """frames: (N, 200, 320) uint8 colour indices; pcm: 8-bit unsigned mono
    audio at 11040 Hz. `lead` silent frames at the start draw the first picture."""
    out = Path(out); out.mkdir(parents=True, exist_ok=True)
    q = np.concatenate([np.repeat(frames[:1], lead, 0), frames])
    st, nfull, costs = plan(q, budget)
    names = []
    for i, x in enumerate(st):
        nm = f"F{i:04d}.BMP"; palette.write_bmp(out / nm, x); names.append(nm)
    pcm = bytes([128]) * (lead * (SR // fps)) + bytes(pcm)
    (out / f"{name}.WAV").write_bytes(struct.pack("<4sI4s4sIHHIIHH4sI", b"RIFF", 36 + len(pcm),
        b"WAVE", b"fmt ", 16, 1, 1, SR, SR, 1, 8, b"data", len(pcm)) + pcm)
    lines = [f"sourcefps={fps}", "screenmode=6", "debug=1", f"waveinput={name}.WAV"] + names
    (out / f"{name}.SCR").write_bytes(("\r\n".join(lines) + "\r\n").encode("ascii"))
    lag = (st != q).mean((1, 2))
    print(f"{len(q)} frames, {nfull} sent exactly, est. cost max {max(costs)} mean {np.mean(costs):.0f} bytes, "
          f"frames behind target {int((lag > 0).sum())}")
