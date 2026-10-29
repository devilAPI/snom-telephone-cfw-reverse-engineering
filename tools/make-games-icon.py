#!/usr/bin/env python3
"""Draw the 24x24 gamepad icon for the phone's Settings -> Games entry.

lcsD375 menus only take built-in icon enums, so the Games entry uses
kIconTypeDect (unused on the D375, no DECT radio) and we overwrite its
dect.png / dect_active.png in every theme. Run from the repo root."""
import struct, zlib

ROOT = "custom-rootfs/snom/bmp/colored"
THEMES = {  # dir: (normal colour, selected colour), sampled from maintenance*.png
    "": ((0x33, 0x33, 0x33), (0x3d, 0x85, 0xc6)),
    "theme_colorful/": ((0xf2, 0xf2, 0xf2), (0x3d, 0x85, 0xc6)),
    "theme_dark/": ((0xf2, 0xf2, 0xf2), (0x3d, 0x85, 0xc6)),
    "theme_industrial/": ((0xf2, 0xf2, 0xf2), (0x3d, 0x85, 0xc6)),
}


def inside(x, y):
    def rrect(x0, y0, x1, y1, r):
        cx = min(max(x, x0 + r), x1 - r)
        cy = min(max(y, y0 + r), y1 - r)
        return (x - cx) ** 2 + (y - cy) ** 2 <= r * r
    body = (rrect(2, 6.5, 22, 15.5, 4.5)
            or (x - 6.5) ** 2 + (y - 15.5) ** 2 <= 4.2 ** 2
            or (x - 17.5) ** 2 + (y - 15.5) ** 2 <= 4.2 ** 2)
    if not body:
        return False
    if (abs(x - 7.2) <= 1.0 and abs(y - 11) <= 3.0) or (abs(y - 11) <= 1.0 and abs(x - 7.2) <= 3.0):
        return False  # d-pad
    return all((x - bx) ** 2 + (y - by) ** 2 > 1.35 ** 2 for bx, by in ((16.3, 12.3), (18.9, 9.7)))


def alpha_mask(ss=8):
    return [[round(255 * sum(inside(px + (sx + .5) / ss, py + (sy + .5) / ss)
                             for sy in range(ss) for sx in range(ss)) / ss ** 2)
             for px in range(24)] for py in range(24)]


def write_png(path, rgb, mask):
    raw = b"".join(b"\0" + bytes(v for a in row for v in (*rgb, a)) for row in mask)
    chunk = lambda t, b: struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 24, 24, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


mask = alpha_mask()
for theme, (normal, active) in THEMES.items():
    base = f"{ROOT}/{theme}icontype_icons/24x24/dect"
    write_png(base + ".png", normal, mask)
    write_png(base + "_active.png", active, mask)
    print("wrote", base + ".png", base + "_active.png")
