#!/usr/bin/env python3
"""Replace a 24x24 menu icon in all four themes from a source image.

lcsD375 menus only take built-in icon enums, so a custom icon replaces an unused
enum's PNG (the Games entry uses `dect`, see make-games-icon.py). Usage, from the repo root:
  tools/theme-icons.py ENUM SRC [--active SRC2] [--colors-from-theme]
ENUM is the file stem in icontype_icons/24x24 (e.g. dect, messages). SRC is any image
(its alpha channel, or if opaque its luminance inverted-from-white, is the shape). The
shape is recoloured per theme like the stock icons: normal colour for ENUM.png, the
blue accent for ENUM_active.png. With --keep-colors SRC is used as-is (resized only)."""
import argparse, os, re, sys
from PIL import Image

ROOT = "custom-rootfs/snom/bmp/colored"
THEMES = {  # dir: (normal colour, selected colour), as in make-games-icon.py
    "": ((0x33, 0x33, 0x33), (0x3d, 0x85, 0xc6)),
    "theme_colorful/": ((0xf2, 0xf2, 0xf2), (0x3d, 0x85, 0xc6)),
    "theme_dark/": ((0xf2, 0xf2, 0xf2), (0x3d, 0x85, 0xc6)),
    "theme_industrial/": ((0xf2, 0xf2, 0xf2), (0x3d, 0x85, 0xc6)),
}


def shape_mask(path):
    im = Image.open(path).convert("RGBA").resize((24, 24), Image.LANCZOS)
    a = im.getchannel("A")
    if a.getextrema() == (255, 255):  # opaque: dark pixels are the shape
        a = im.convert("L").point(lambda v: 255 - v)
    return a


def recolour(mask, rgb):
    out = Image.new("RGBA", (24, 24), rgb + (0,))
    out.putalpha(mask)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("enum"); ap.add_argument("src")
    ap.add_argument("--active", help="separate source for the _active (selected) icon")
    ap.add_argument("--keep-colors", action="store_true", help="do not recolour, only resize")
    ap.add_argument("--root", default=ROOT)
    o = ap.parse_args(argv)
    if not re.fullmatch(r"[a-z0-9_]+", o.enum) or o.enum.endswith("_active"):
        sys.exit("ENUM must be a plain stem like dect or messages")
    for theme, (normal, active) in THEMES.items():
        base = f"{o.root}/{theme}icontype_icons/24x24/{o.enum}"
        if not os.path.exists(base + ".png"):
            sys.exit(f"no such icon: {base}.png")
        for suffix, rgb, src in (("", normal, o.src), ("_active", active, o.active or o.src)):
            if o.keep_colors:
                img = Image.open(src).convert("RGBA").resize((24, 24), Image.LANCZOS)
            else:
                img = recolour(shape_mask(src), rgb)
            img.save(base + suffix + ".png", optimize=True)
            print("wrote", base + suffix + ".png")


if __name__ == "__main__":
    main()
