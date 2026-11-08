#!/usr/bin/env bash
# Cross-build a static htop 3.3.0 for the D375. Output: out/htop. Needs docker.
# See docs/ssh-update.md.
. "$(dirname "$0")/lib.sh"
PKGS="gcc autoconf automake pkg-config" musl_run '
export CC=$X-gcc CFLAGS="-Os -march=armv4t"
ncurses_static /opt/arm
wget -q -O htop.tar.xz https://github.com/htop-dev/htop/releases/download/3.3.0/htop-3.3.0.tar.xz
tar xf htop.tar.xz && cd htop-3.3.0
./configure --host=$X --prefix=/usr --disable-unicode --enable-static \
    --disable-hwloc --disable-sensors --disable-capabilities --disable-delayacct \
    CPPFLAGS="-I/opt/arm/include -I/opt/arm/include/ncurses" \
    LDFLAGS="-static -L/opt/arm/lib" LIBS="-lncurses" HTOP_NCURSES_CONFIG_SCRIPT=/bin/false >/dev/null
make -j"$(nproc)" >/dev/null 2>&1
cp htop /out/htop
$X-strip /out/htop
chown '"$(id -u):$(id -g)"' /out/htop
file /out/htop'
