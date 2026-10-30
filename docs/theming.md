# Boot splash and theme icons

Two ways to restyle the phone without touching closed binaries: the boot splash (painted by `rcS`) and the 24x24 menu icons (PNG files the closed UI loads by name).

## Boot splash

### Format
`snom/bmp/colored/splash_screen.png` is **480x272, 8-bit palette PNG (mode P, 17 colours)**. The D375 panel is 480x272, so the image is 1:1. `rcS` paints it with `fbApp showFb 0 0 <png>` from `display "&&" "$splashPng"` (called when the file systems are mounted, before an update restart, ...). `splashPng` is only set for some phone types; the D375 uses the path above.

Measured on the device (`fbApp` is the closed snom helper, `/bin/fbApp`):

* a palette PNG, a truecolour RGB PNG and an RGBA PNG all paint fine (exit 0), so any PNG of the right size works, no 17-colour limit;
* a missing file or a non-PNG file returns exit status 255 and paints nothing. This is what makes a safe fallback possible.

### How the custom splash is chosen (rcS)
In the D375 branch of `display()`:

```sh
if [ "$2" = "/snom/bmp/colored/splash_screen.png" ] && [ -s /snom/cfw-data/splash.png ] \
   && fbApp showFb 0 0 /snom/cfw-data/splash.png >/dev/null 2>&1; then :
else fbApp showFb 0 0 "$2" >/dev/null 2>&1; fi
```

So `/snom/cfw-data/splash.png` wins when it exists and `fbApp` accepts it; any failure paints the stock image. The stock file stays in the image untouched. Only calls asking for the stock splash are redirected (progress/update screens with other images are not).

Why a data file and not an image replacement: `/snom/cfw-data` is writable at runtime (no flash needed, no signed image rebuild) and survives reboots. Gotcha: it is not part of the image, so a firmware flash that rewrites the rootfs may wipe it. Check after flashing.

A reboot is needed to see a change: nothing repaints the splash at runtime.

### Making an image
```sh
tools/make-splash.py photo.jpg out.png                  # crop to fill (default)
tools/make-splash.py logo.png out.png --fit contain --bg 101830
```
Output is always 480x272 mode P (256 colours, Floyd-Steinberg). Options: `--fit cover|contain|stretch`, `--colors N`, `--bg RRGGBB` (letterbox and transparency background). To bake it into the image instead, overwrite `custom-rootfs/snom/bmp/colored/splash_screen.png`.

### Web panel upload
Panel card "Boot splash" (`panel.d/80-splash.html`, CGI `cgi-bin/splash`). The browser scales/crops the chosen image on a canvas and POSTs a 480x272 PNG as the raw body. Multipart parsing in busybox sh is not worth it, so the browser does the conversion. The CGI:

* accepts only POST with a Content-Length of 33..300000 bytes, writes to `splash.png.tmp`, checks the PNG signature and that IHDR says 480x272, then `mv`s into place. Anything else is rejected and the temp file removed, so the old splash survives;
* never uses a client-supplied name, so there is no path to traverse; `act` must match `[a-z]*` and is only used in a `case`;
* reports a readable error when the write fails (flash full or read-only) and checks for a short write;
* `act=remove` deletes the custom file, `act=preview` serves the PNG in use, `act=status` prints `custom` or `stock`.

The busybox `od` on the phone only has `-b` (octal bytes), no `-t x1`; the CGI parses `od -b` output. That cost a debugging round, hence this note.

### Testing
`tests/splash.sh` (add `--boot` to reboot under the phone lock). The splash is painted before httpd/sshd exist, so a screenshot by polling after boot is too late; see the test for how the boot-time framebuffer was captured.

## Theme icons

lcsD375 menus only take built-in icon enums, so a custom icon means overwriting the PNG of an enum you do not use. The Games entry uses `kIconTypeDect` (no DECT radio on the D375) and its art is `icontype_icons/24x24/dect.png` plus `dect_active.png` (the selected state) in all four themes: the base dir and `theme_colorful/`, `theme_dark/`, `theme_industrial/`.

```sh
tools/theme-icons.py ENUM SRC [--active SRC2] [--keep-colors]
tools/theme-icons.py dect my-icon.png          # recolours the shape per theme
```
`ENUM` is the file stem in `icontype_icons/24x24/` (`dect`, `messages`, `network`, ...; the tool refuses unknown ones). The source is resized to 24x24; its alpha channel is the shape (an opaque image is read as dark-on-light). The shape is recoloured per theme like the stock icons: `#333` on the light theme, `#f2f2f2` on dark themes, accent `#3d85c6` for `_active`. `--keep-colors` only resizes (for full-colour icons). `tools/make-games-icon.py` is the original, hand-drawn variant of the same idea.

The icons are part of the signed image, so a change needs a firmware rebuild.

### Boot capture (verified)
sshd and httpd start after the splash is gone, so the test build of rcS (the CFW hunk plus a temporary `head -c 522240 /dev/fb0 > /tmp/fbsplash.raw` right after the paint) was flashed to the running rootfs, a plain-green 480x272 PNG uploaded through the CGI, and the phone rebooted. The dumped framebuffer (BGRX) is `docs/img/splash-boot-capture.png`: solid (20,160,60), i.e. the custom splash was painted by rcS. The capture line is not in the shipped rcS; the device's original rcS was restored afterwards.
