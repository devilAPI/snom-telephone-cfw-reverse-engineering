#!/usr/bin/env bash
# Cross-build navplay, the Navidrome player's MP3 decoder (docs/navidrome.md), with
# libmad 0.15.1b (GPL-2, fixed point). Output: out/navplay, shipped in
# /snom/cfw/navidrome. Needs docker.
. "$(dirname "$0")/lib.sh"
musl_run -v "$ROOT/src/audio/navidrome":/src:ro '
wget -q https://deb.debian.org/debian/pool/main/libm/libmad/libmad_0.15.1b.orig.tar.gz
echo "bbfac3ed6bfbc2823d3775ebb931087371e142bb0e9bb1bee51a76a6e0078690  libmad_0.15.1b.orig.tar.gz" | sha256sum -c -
tar xzf libmad_0.15.1b.orig.tar.gz
cd libmad-0.15.1b
# No configure: a fixed config for 32-bit ARM, fixed point with ARM asm (FPM_ARM).
printf "#define SIZEOF_INT 4\n#define SIZEOF_LONG 4\n#define SIZEOF_LONG_LONG 8\n#define OPT_SPEED 1\n" > config.h
F="-O2 -march=armv6 -marm -msoft-float -DHAVE_CONFIG_H -DFPM_ARM -include stdlib.h -I."
for c in bit decoder fixed frame huffman layer12 layer3 stream synth timer version; do
    $X-gcc $F -c $c.c -o $c.o
done
$X-gcc $F -Wall -static -no-pie -o /out/navplay /src/navplay.c *.o
$X-strip /out/navplay
file /out/navplay'
ship navplay "$CFW/navidrome"
