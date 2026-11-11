#!/usr/bin/env python3
"""Build a 10 second 160x100x16 clip with a real 8-bit soundtrack.

The rate is 11040 Hz and the frame rate is 60, so each audio chunk is
184 bytes and XDC_COMP does not have to stretch the sample rate.
A logarithmic sweep from 220 Hz to 1760 Hz runs under the pictures.
The white bar steps right once per second, so the last frame is obvious.

Writes F0.BMP..F9.BMP, TONE.WAV and CLIP.SCR into the directory given
on the command line (default: lab/clip).
"""

import math
import struct
import sys
from pathlib import Path

W, H = 160, 100
FPS = 60
RATE = 11040
SECONDS = 10
FRAMES = FPS * SECONDS

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
    """phase is 0..9, one value per second."""
    if x < 2 or x >= W - 2 or y < 2 or y >= H - 2:
        return 15
    # A 6-pixel white bar. It starts near the left and ends near the right.
    bar = 8 + phase * 14
    if bar <= x < bar + 6 and 8 <= y < 92:
        return 15
    if x < 80:
        return (x - 2) * 16 // 76
    return (y - 2) * 16 // 96


def frame_pixels(phase):
    return [pixel(x, y, phase) for y in range(H) for x in range(W)]


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


def write_wav(path):
    # Continuous log sweep. Integer rate/fps keeps the muxer from dropping frames.
    n = RATE * SECONDS
    f0, f1 = 220.0, 1760.0
    curve = math.log(f1 / f0) / SECONDS
    phase = 0.0
    data = bytearray(n)
    for i in range(n):
        freq = f0 * math.exp(curve * (i / RATE))
        phase += freq / RATE
        sample = 128 + int(round(60.0 * math.sin(2.0 * math.pi * phase)))
        if sample < 1:
            sample = 1
        elif sample > 254:
            sample = 254
        data[i] = sample
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
        "screenmode=5",
        "debug=0",
        "waveinput=TONE.WAV",
    ]
    for phase in range(SECONDS):
        lines.extend([f"F{phase}.BMP"] * FPS)
    path.write_bytes(("\r\n".join(lines) + "\r\n").encode("ascii"))


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "lab/clip")
    out.mkdir(parents=True, exist_ok=True)
    for phase in range(SECONDS):
        write_bmp(out / f"F{phase}.BMP", phase)
    write_wav(out / "TONE.WAV")
    write_script(out / "CLIP.SCR")
    print(
        f"wrote {out} ({FRAMES} frames, {RATE} Hz, "
        f"{RATE // FPS} samples/frame)"
    )


if __name__ == "__main__":
    main()
