#!/usr/bin/env python3
"""Generate a 160x100x16 RGBI test clip for the silent XDC player.

Pixel index is the RGBI color (0..15). The compiler packs each pair into
one text attribute: background = left pixel, foreground = right pixel.

Writes FRAME.BMP, SILENCE.WAV and CLIP.SCR into the directory given on
the command line (default: lab/out/clip).
"""

import struct
import sys
from pathlib import Path

W, H = 160, 100
# CGA RGB palette, matching palette/CGA 16-color RGB palette.txt
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


def pixel(x, y):
    # One-pixel border, then vertical bars on the left, horizontal bars
    # on the right, and a yellow X so a bad row height is obvious.
    if x < 2 or x >= W - 2 or y < 2 or y >= H - 2:
        return 15
    if abs(x - y) < 2 or abs(x - (H - 1 - y)) < 2:
        return 14
    if x < 80:
        return (x - 2) * 16 // 76
    return (y - 2) * 16 // 96


def write_bmp(path):
    pixels = bytearray(pixel(x, y) for y in range(H) for x in range(W))
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
    # BMP rows are bottom-up. Store the last row first.
    rows = b"".join(pixels[y * W : (y + 1) * W] for y in range(H - 1, -1, -1))
    path.write_bytes(header + info + palette + rows)


def write_wav(path, frames=16, fps=60, rate=6000):
    # 8-bit unsigned silence. rate/fps is an integer so the compiler
    # does not have to stretch the sample rate.
    nsamp = frames * (rate // fps)
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
        rate,
        rate,
        1,
        8,
        b"data",
        len(data),
    )
    path.write_bytes(header + data)


def write_script(path, repeats=16):
    lines = [
        "sourcefps=60",
        "screenmode=5",
        "debug=1",
        "waveinput=SILENCE.WAV",
    ]
    lines.extend(["FRAME.BMP"] * repeats)
    path.write_bytes(("\r\n".join(lines) + "\r\n").encode("ascii"))


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "lab/out/clip")
    out.mkdir(parents=True, exist_ok=True)
    write_bmp(out / "FRAME.BMP")
    write_wav(out / "SILENCE.WAV")
    write_script(out / "CLIP.SCR")
    print(f"wrote {out}/FRAME.BMP, SILENCE.WAV, CLIP.SCR")


if __name__ == "__main__":
    main()
