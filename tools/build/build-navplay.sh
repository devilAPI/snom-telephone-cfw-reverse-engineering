#!/usr/bin/env bash
# Cross-build navplay (Navidrome player's MP3 decoder, see docs/navidrome.md) as a static
# musl armv6 soft-float binary with libmad 0.15.1b (GPL-2, fixed point). Needs docker.
# Output: out/navplay, copied to rootfs/d375/snom/cfw/navidrome/navplay.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/out"; mkdir -p "$OUT"

docker run --rm \
  -v "$ROOT/src/audio/navidrome":/src:ro \
  -v "$OUT":/out \
  debian:bookworm-slim bash -euo pipefail -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wget ca-certificates file >/dev/null
cd /opt
wget -q https://musl.cc/arm-linux-musleabi-cross.tgz
tar xf arm-linux-musleabi-cross.tgz
export PATH=/opt/arm-linux-musleabi-cross/bin:$PATH
wget -q https://deb.debian.org/debian/pool/main/libm/libmad/libmad_0.15.1b.orig.tar.gz
echo "bbfac3ed6bfbc2823d3775ebb931087371e142bb0e9bb1bee51a76a6e0078690  libmad_0.15.1b.orig.tar.gz" | sha256sum -c -
tar xzf libmad_0.15.1b.orig.tar.gz
cd libmad-0.15.1b
# no configure: a fixed config for 32-bit ARM, fixed point with ARM asm (FPM_ARM)
printf "#define SIZEOF_INT 4\n#define SIZEOF_LONG 4\n#define SIZEOF_LONG_LONG 8\n#define OPT_SPEED 1\n" > config.h
F="-O2 -march=armv6 -marm -msoft-float -DHAVE_CONFIG_H -DFPM_ARM -include stdlib.h -I."
for c in bit decoder fixed frame huffman layer12 layer3 stream synth timer version; do
    arm-linux-musleabi-gcc $F -c $c.c -o $c.o
done
arm-linux-musleabi-gcc $F -Wall -static -no-pie -o /out/navplay /src/navplay.c *.o
arm-linux-musleabi-strip /out/navplay
file /out/navplay
'
mkdir -p "$ROOT/rootfs/d375/snom/cfw/navidrome"
cp "$OUT/navplay" "$ROOT/rootfs/d375/snom/cfw/navidrome/navplay"
chmod 755 "$ROOT/rootfs/d375/snom/cfw/navidrome/navplay"
echo "built: $OUT/navplay"
