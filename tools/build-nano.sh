#!/usr/bin/env bash
# Cross-build a static musl `nano` that runs on the snom D375
# (ARMv6 softfloat, kernel 2.6.27). Needs docker. Output: tools/out/nano.
# See docs/building-nano.md for why musl + softfloat + static.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/out"
mkdir -p "$OUT"

docker run --rm -v "$OUT":/out debian:bookworm-slim bash -euo pipefail -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq gcc make wget xz-utils ca-certificates file >/dev/null

cd /opt
wget -q https://musl.cc/arm-linux-musleabi-cross.tgz
tar xf arm-linux-musleabi-cross.tgz
export PATH=/opt/arm-linux-musleabi-cross/bin:$PATH

PREFIX=/opt/arm; HOST=arm-linux-musleabi
export CC=${HOST}-gcc CFLAGS="-Os -march=armv4t"
mkdir -p /src "$PREFIX"; cd /src

wget -q https://ftp.gnu.org/gnu/ncurses/ncurses-6.4.tar.gz
wget -q https://www.nano-editor.org/dist/v7/nano-7.2.tar.xz
tar xf ncurses-6.4.tar.gz; tar xf nano-7.2.tar.xz

cd /src/ncurses-6.4
./configure --host=${HOST} --prefix=${PREFIX} \
  --without-shared --without-debug --without-ada --without-cxx-binding \
  --without-manpages --without-progs --without-tests --disable-db-install \
  --enable-widec --without-pkg-config --without-develop \
  --with-fallbacks=linux,vt100,vt102,xterm,xterm-256color,ansi,screen \
  --disable-database --with-build-cc=gcc >/dev/null
make -j"$(nproc)" >/dev/null 2>&1; make install >/dev/null 2>&1

cd /src/nano-7.2
./configure --host=${HOST} --prefix=${PREFIX} \
  --disable-nls --disable-libmagic --disable-speller \
  CPPFLAGS="-I${PREFIX}/include -I${PREFIX}/include/ncursesw" \
  LDFLAGS="-static -L${PREFIX}/lib" LIBS="-lncursesw" >/dev/null
make -j"$(nproc)" >/dev/null 2>&1

cp src/nano /out/nano
${HOST}-strip /out/nano
file /out/nano
'
echo "built: $OUT/nano"
