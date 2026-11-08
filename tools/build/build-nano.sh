#!/usr/bin/env bash
# Cross-build a static `nano` 7.2 for the D375. Output: out/nano. Needs docker.
# See docs/building-nano.md for why musl + softfloat + static.
. "$(dirname "$0")/lib.sh"
PKGS=gcc musl_run '
export CC=$X-gcc CFLAGS="-Os -march=armv4t"
ncurses_static /opt/arm --enable-widec
wget -q https://www.nano-editor.org/dist/v7/nano-7.2.tar.xz && tar xf nano-7.2.tar.xz
cd nano-7.2
./configure --host=$X --prefix=/opt/arm --disable-nls --disable-libmagic --disable-speller \
    CPPFLAGS="-I/opt/arm/include -I/opt/arm/include/ncursesw" \
    LDFLAGS="-static -L/opt/arm/lib" LIBS="-lncursesw" >/dev/null
make -j"$(nproc)" >/dev/null 2>&1
cp src/nano /out/nano
$X-strip /out/nano
file /out/nano'
