#!/usr/bin/env python3
"""Convert any image to the D375 boot-splash format (480x272, 8-bit palette PNG).

The stock snom/bmp/colored/splash_screen.png is 480x272, mode P (17 colours).
rcS paints it with `fbApp showFb 0 0 <png>`. Usage:
  tools/make-splash.py SRC OUT.png [--fit cover|contain|stretch] [--colors N] [--bg RRGGBB]
OUT.png can be replaced into the image (custom-rootfs/snom/bmp/colored/splash_screen.png)
or uploaded in the web panel (stored as /snom/cfw-data/splash.png)."""
import argparse, sys
from PIL import Image, ImageOps

W, H = 480, 272


def make(src, out, fit="cover", colors=256, bg=(0, 0, 0)):
    im = Image.open(src)
    im = ImageOps.exif_transpose(im)
    if im.mode in ("RGBA", "LA", "P"):
        im = im.convert("RGBA")
        base = Image.new("RGBA", im.size, bg + (255,))
        im = Image.alpha_composite(base, im)
    im = im.convert("RGB")
    if fit == "stretch":
        im = im.resize((W, H), Image.LANCZOS)
    elif fit == "cover":
        im = ImageOps.fit(im, (W, H), Image.LANCZOS)
    else:  # contain: letterbox on bg
        c = ImageOps.contain(im, (W, H), Image.LANCZOS)
        im = Image.new("RGB", (W, H), bg)
        im.paste(c, ((W - c.width) // 2, (H - c.height) // 2))
    p = im.quantize(colors=colors, method=Image.MEDIANCUT, dither=Image.FLOYDSTEINBERG)
    p.save(out, optimize=True)
    return p


if __name__ == "__main__":
    a = argparse.ArgumentParser()
    a.add_argument("src"); a.add_argument("out")
    a.add_argument("--fit", choices=["cover", "contain", "stretch"], default="cover")
    a.add_argument("--colors", type=int, default=256)
    a.add_argument("--bg", default="000000")
    o = a.parse_args()
    bg = tuple(int(o.bg[i:i + 2], 16) for i in (0, 2, 4))
    p = make(o.src, o.out, o.fit, o.colors, bg)
    print(f"wrote {o.out}: {p.size[0]}x{p.size[1]} mode {p.mode}")
