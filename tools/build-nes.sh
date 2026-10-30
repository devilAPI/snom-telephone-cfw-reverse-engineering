#!/usr/bin/env bash
# Cross-build the InfoNES NES emulator (snom D375 fb/evdev port) as a static
# musl armv6 binary. Needs docker. Output: tools/out/infones.
# See docs/nes.md.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
OUT="$HERE/out"; mkdir -p "$OUT"

docker run --rm \
  -v "$ROOT/nes-src":/port \
  -v "$ROOT/snd":/snd \
  -v "$OUT":/out \
  debian:bookworm-slim bash -euo pipefail -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git wget xz-utils ca-certificates file >/dev/null
cd /opt
wget -q https://musl.cc/arm-linux-musleabi-cross.tgz
tar xf arm-linux-musleabi-cross.tgz
export PATH=/opt/arm-linux-musleabi-cross/bin:$PATH

git clone --depth 1 https://github.com/jay-kumogata/InfoNES.git /src >/dev/null 2>&1
cp /port/InfoNES_System_snom.cpp /src/src/
cp /snd/snd_hal.h /snd/snd_hal.c /src/src/
cd /src/src
# APU at 22050 Hz instead of 44100: half the per-sample APU work; the codec runs
# at 16 kHz anyway (snd_hal box-filters down).
sed -i "s/^#define pAPU_QUALITY 3/#define pAPU_QUALITY 2/" InfoNES_pAPU.h
grep -q "^#define pAPU_QUALITY 2" InfoNES_pAPU.h
# ARM1176 = armv6, ARM mode, no VFP (soft-float).
FLAGS="-O2 -march=armv6 -marm -fomit-frame-pointer -fsigned-char -Wno-write-strings -I."
# snd_hal.c is C; compile it with the C compiler, link everything with g++.
arm-linux-musleabi-gcc -O2 -march=armv6 -marm -fomit-frame-pointer -I. -c snd_hal.c -o snd_hal.o
arm-linux-musleabi-g++ $FLAGS -static -o /out/infones \
    K6502.cpp InfoNES.cpp InfoNES_Mapper.cpp InfoNES_pAPU.cpp InfoNES_System_snom.cpp \
    snd_hal.o -lm -lpthread
arm-linux-musleabi-strip /out/infones
file /out/infones
'
echo "built: $OUT/infones"
