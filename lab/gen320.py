#!/usr/bin/env python3
"""Generate a 320x200x16 EGA test clip (BIOS mode 0Dh, screenmode 6).

Sixteen horizontal colour bars, then a 32x32 white square that steps
right by 24 pixels. Bars are full-width runs of 00h/FFh inside each
plane, which is the cheap encoding. The square is byte-aligned so a
move touches whole plane bytes.

Pixel index is the default EGA colour, the same RGBI set as CGA.
The compiler maps BMP palette entries to those 16 colours.

Writes F0.BMP..F7.BMP, SILENCE.WAV and CLIP.SCR into the directory
given on the command line (default: lab/out/ega).
"""

import struct
import sys
from pathlib import Path

W, H = 320, 200
FPS = 60
RATE = 6000  # divides by 60, so each audio chunk is 100 bytes
HOLD0 = 30   # first picture is repeated while the runs finish
HOLD = 8
PHASES = 8

RGBI = [
    (0x00, 0x00, 0x00),
    (0x00, 0x00, 0xAA),
    (0x00, 0xAA, 0x00),
    (0x00, 0xAA, 0xAA),
    (0xAA, 0x00, 0x00),
    (0xAA, 0x00, 0xAA),
    (0xAA, 0x55, 0x00),
    (0xAA, 0xAA, 0xAA),
    (0x55, 0x55, 0x55),
    (0x55, 0x55, 0xFF),
    (0x55, 0xFF, 0x55),
    (0x55, 0xFF, 0xFF),
    (0xFF, 0x55, 0x55),
    (0xFF, 0x55, 0xFF),
    (0xFF, 0xFF, 0x55),
    (0xFF, 0xFF, 0xFF),
]


def pixel(x, y, phase):
    # Square sits on bars 6..9. White against those colours updates only
    # the planes whose bit differs, which is the case the encoder cares about.
    sx = 8 + phase * 24
    if sx <= x < sx + 32 and 80 <= y < 112:
        return 15
    if y < 192:
        return y // 12
    return 0


def frame_pixels(phase):
    return [pixel(x, y, phase) for y in range(H) for x in range(W)]


def pack_planes(pixels):
    """Match the compiler: MSB is the leftmost pixel, four planes of 8000."""
    planes = [bytearray(8000) for _ in range(4)]
    for y in range(H):
        row = y * W
        base = y * 40
        for x in range(0, W, 8):
            b = [0, 0, 0, 0]
            for bit in range(8):
                color = pixels[row + x + bit] & 0x0F
                for plane in range(4):
                    b[plane] = (b[plane] << 1) & 0xFF
                    if color & (1 << plane):
                        b[plane] |= 1
            off = base + x // 8
            for plane in range(4):
                planes[plane][off] = b[plane]
    return planes


def write_bmp(path, phase):
    pixels = bytes(frame_pixels(phase))
    palette = b"".join(bytes((b, g, r, 0)) for r, g, b in RGBI)
    header = struct.pack(
        "<2sIHHI",
        b"BM",
        14 + 40 + len(palette) + len(pixels),
        0,
        0,
        14 + 40 + len(palette),
    )
    info = struct.pack(
        "<IiiHHIIiiII",
        40,
        W,
        H,
        1,
        8,
        0,
        len(pixels),
        0,
        0,
        16,
        0,
    )
    rows = b"".join(pixels[y * W : (y + 1) * W] for y in range(H - 1, -1, -1))
    path.write_bytes(header + info + palette + rows)


def write_wav(path, frames):
    nsamp = frames * (RATE // FPS)
    data = bytes([128]) * nsamp
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF",
        36 + len(data),
        b"WAVE",
        b"fmt ",
        16,
        1,
        1,
        RATE,
        RATE,
        1,
        8,
        b"data",
        len(data),
    )
    path.write_bytes(header + data)


def write_script(path):
    lines = [
        "sourcefps=60",
        "screenmode=6",
        "debug=1",
        "waveinput=SILENCE.WAV",
    ]
    lines.extend(["F0.BMP"] * HOLD0)
    for phase in range(1, PHASES):
        lines.extend([f"F{phase}.BMP"] * HOLD)
    path.write_bytes(("\r\n".join(lines) + "\r\n").encode("ascii"))


def changed_bytes(prev, nxt):
    total = 0
    runs = 0
    for a, b in zip(prev, nxt):
        diff = bytes(x != y for x, y in zip(a, b))
        i = 0
        while i < len(diff):
            if not diff[i]:
                i += 1
                continue
            j = i
            while j < len(diff) and diff[j]:
                j += 1
            total += j - i
            # A run is a stretch of one fill value at least 9 bytes long,
            # the compiler's REP STOS threshold.
            k = i
            while k < j:
                m = k
                while m < j and b[m] == b[k]:
                    m += 1
                if m - k >= 9:
                    runs += m - k
                k = m
            i = j
    return total, runs


def self_check():
    pixels = frame_pixels(0)
    planes = pack_planes(pixels)
    # Colour 1 is blue: plane 0 set, the others clear. Bar 1 is rows 12..23.
    assert planes[0][12 * 40] == 0xFF
    assert planes[1][12 * 40] == 0x00
    assert planes[2][12 * 40] == 0x00
    assert planes[3][12 * 40] == 0x00
    # White square, byte aligned, sets every plane.
    assert planes[0][80 * 40 + 1] == 0xFF
    assert planes[3][80 * 40 + 1] == 0xFF
    # Outside the square the bar colour is unchanged.
    assert planes[0][80 * 40] == 0x00  # colour 6 has no blue
    black = [bytearray(8000) for _ in range(4)]
    total, runs = changed_bytes(black, planes)
    assert runs > total * 0.8
    return total, runs


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "lab/out/ega")
    out.mkdir(parents=True, exist_ok=True)
    frames = HOLD0 + HOLD * (PHASES - 1)
    for phase in range(PHASES):
        write_bmp(out / f"F{phase}.BMP", phase)
    write_wav(out / "SILENCE.WAV", frames)
    write_script(out / "CLIP.SCR")
    total, runs = self_check()
    step, step_runs = changed_bytes(pack_planes(frame_pixels(0)), pack_planes(frame_pixels(1)))
    print(
        f"wrote {out} ({frames} frames, {RATE} Hz, {RATE // FPS} samples/frame, "
        f"first picture {total} changed bytes, {runs} of them runs, "
        f"one square step {step} bytes)"
    )


if __name__ == "__main__":
    main()
