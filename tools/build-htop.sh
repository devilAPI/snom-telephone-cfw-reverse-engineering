#!/usr/bin/env bash
# Cross-build a static musl htop for the D375. Needs docker. Output: tools/out/htop.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/out"; mkdir -p "$OUT"

docker run --rm -v "$OUT":/out debian:bookworm-slim bash -euo pipefail -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq gcc make wget xz-utils ca-certificates file autoconf automake pkg-config >/dev/null
cd /opt
wget -q https://musl.cc/arm-linux-musleabi-cross.tgz
tar xf arm-linux-musleabi-cross.tgz
export PATH=/opt/arm-linux-musleabi-cross/bin:$PATH
PREFIX=/opt/arm; HOST=arm-linux-musleabi
export CC=${HOST}-gcc CFLAGS="-Os -march=armv4t"
mkdir -p /src $PREFIX; cd /src
wget -q https://ftp.gnu.org/gnu/ncurses/ncurses-6.4.tar.gz
wget -q -O htop.tar.xz https://github.com/htop-dev/htop/releases/download/3.3.0/htop-3.3.0.tar.xz
tar xf ncurses-6.4.tar.gz; tar xf htop.tar.xz

cd ncurses-6.4
./configure --host=$HOST --prefix=$PREFIX --without-shared --without-debug \
  --without-ada --without-cxx-binding --without-manpages --without-progs \
  --without-tests --disable-db-install --without-pkg-config --without-develop \
  --with-fallbacks=linux,vt100,vt102,xterm,xterm-256color,ansi,screen \
  --disable-database --with-build-cc=gcc >/dev/null
make -j$(nproc) >/dev/null 2>&1; make install >/dev/null 2>&1

cd ../htop-3.3.0
./configure --host=$HOST --prefix=/usr --disable-unicode --enable-static \
  --disable-hwloc --disable-sensors --disable-capabilities --disable-delayacct \
  CPPFLAGS="-I$PREFIX/include -I$PREFIX/include/ncurses" \
  LDFLAGS="-static -L$PREFIX/lib" LIBS="-lncurses" HTOP_NCURSES_CONFIG_SCRIPT=/bin/false >/dev/null
make -j$(nproc) >/dev/null 2>&1
cp htop /out/htop
${HOST}-strip /out/htop
chown '"$(id -u):$(id -g)"' /out/htop
'
file "$OUT/htop"; ls -la "$OUT/htop"
