"""The 16 RGBI colours used by CGA and EGA, colour-space helpers, and an
8-bit indexed BMP writer (XDP_COMP reads 8-bit BMPs whose pixel values are
the 16 RGBI colour indices)."""
import struct
import numpy as np

RGBI = np.array([
 (0x00,0x00,0x00),(0x00,0x00,0xAA),(0x00,0xAA,0x00),(0x00,0xAA,0xAA),
 (0xAA,0x00,0x00),(0xAA,0x00,0xAA),(0xAA,0x55,0x00),(0xAA,0xAA,0xAA),
 (0x55,0x55,0x55),(0x55,0x55,0xFF),(0x55,0xFF,0x55),(0x55,0xFF,0xFF),
 (0xFF,0x55,0x55),(0xFF,0x55,0xFF),(0xFF,0xFF,0x55),(0xFF,0xFF,0xFF)], np.float64)

def to_lin(c):
    """sRGB 0..255 -> linear light 0..1"""
    c = c / 255.0
    return np.where(c > 0.04045, ((c + 0.055) / 1.055) ** 2.4, c / 12.92)

def lin_to_lab(c):
    """linear RGB -> CIELAB (D65)"""
    M = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722],
                  [0.0193, 0.1192, 0.9505]])
    xyz = c @ M.T / np.array([0.9505, 1.0, 1.089])
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]),
                     200 * (f[..., 1] - f[..., 2])], -1)

def write_bmp(path, idx):
    """write an (H, W) array of colour indices 0..15 as an 8-bit BMP"""
    H, W = idx.shape
    pal = b"".join(bytes((int(b), int(g), int(r), 0)) for r, g, b in RGBI)
    rows = idx[::-1].tobytes(); off = 14 + 40 + len(pal)
    path.write_bytes(struct.pack("<2sIHHI", b"BM", off + len(rows), 0, 0, off)
        + struct.pack("<IiiHHIIiiII", 40, W, H, 1, 8, 0, len(rows), 0, 0, 16, 0) + pal + rows)
