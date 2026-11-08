# Shared by the cross-build scripts:  . "$(dirname "$0")/lib.sh"
#   ROOT  repo root
#   OUT   out/, mounted at /out in the container
#   CFW   rootfs/d375/snom/cfw, where the D375 image picks the binaries up
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OUT="$ROOT/out" CFW="$ROOT/rootfs/d375/snom/cfw"
mkdir -p "$OUT"

# Runs in the container before each build script: the musl.cc toolchain on PATH
# (static binaries for the D375's ARM1176, armv6 without VFP) with X as its prefix.
PRELUDE='
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git make wget xz-utils bzip2 ca-certificates file $PKGS >/dev/null
cd /opt
wget -q https://musl.cc/arm-linux-musleabi-cross.tgz
tar xf arm-linux-musleabi-cross.tgz
export PATH=/opt/arm-linux-musleabi-cross/bin:$PATH
X=arm-linux-musleabi
# ncurses_static PREFIX [configure args]: static ncurses 6.4 with built-in terminfo
# for the usual terminals (the phone has no terminfo database). Built in /src.
ncurses_static() {
    local p=$1; shift
    mkdir -p /src && cd /src
    wget -q https://ftp.gnu.org/gnu/ncurses/ncurses-6.4.tar.gz && tar xf ncurses-6.4.tar.gz
    cd ncurses-6.4
    ./configure --host=$X --prefix=$p --without-shared --without-debug --without-ada \
        --without-cxx-binding --without-manpages --without-progs --without-tests \
        --disable-db-install --without-pkg-config --without-develop \
        --with-fallbacks=linux,vt100,vt102,xterm,xterm-256color,ansi,screen \
        --disable-database --with-build-cc=gcc "$@" >/dev/null
    make -j"$(nproc)" >/dev/null 2>&1; make install >/dev/null 2>&1
    cd /src
}
'

# musl_run [docker args...] SCRIPT: run SCRIPT in debian bookworm after PRELUDE.
# PKGS=... adds apt packages.
musl_run() {
    local script=${!#}
    docker run --rm -e PKGS="${PKGS:-}" -v "$OUT":/out "${@:1:$#-1}" debian:bookworm-slim \
        bash -euo pipefail -c "$PRELUDE$script"
}

# ship BIN... DIR: copy binaries from out/ into DIR (in the D375 rootfs), mode 755.
ship() {
    local dir=${!#} b
    mkdir -p "$dir"
    for b in "${@:1:$#-1}"; do cp "$OUT/$b" "$dir/"; chmod 755 "$dir/$b"; done
}
