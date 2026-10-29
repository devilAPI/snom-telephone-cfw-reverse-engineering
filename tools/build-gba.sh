#!/usr/bin/env bash
# Cross-build the gpSP GBA emulator (libretro core, ARM dynarec) with the snom
# D375 fb/evdev/snd_hal frontend as a static musl armv6 binary. Needs docker.
# Output: tools/out/gpsp. See docs/gba.md.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
OUT="$HERE/out"; mkdir -p "$OUT"

GPSP_COMMIT=5819380c2ffb0900219d700a382ee68c464ebb99   # libretro/gpsp, 2026-09-19
ROM_BUFFER_MB=${ROM_BUFFER_MB:-8}   # ROM kept in RAM; larger ROMs page in from the file

docker run --rm \
  -e GPSP_COMMIT="$GPSP_COMMIT" -e ROM_BUFFER_MB="$ROM_BUFFER_MB" \
  -v "$ROOT/gba-src":/port \
  -v "$ROOT/snd":/snd \
  -v "$OUT":/out \
  debian:bookworm-slim bash -euo pipefail -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git wget xz-utils ca-certificates file make >/dev/null
cd /opt
wget -q https://musl.cc/arm-linux-musleabi-cross.tgz
tar xf arm-linux-musleabi-cross.tgz
export PATH=/opt/arm-linux-musleabi-cross/bin:$PATH
X=arm-linux-musleabi

git clone -q https://github.com/libretro/gpsp.git /src
cd /src && git checkout -q "$GPSP_COMMIT"

# The D375 CPU is an ARM1176 (armv6, no VFP): soft-float, ARM mode.
# CFLAGS/ASFLAGS go in via the environment so the Makefile can still append.
export CFLAGS="-march=armv6 -marm -DROM_BUFFER_SIZE=$ROM_BUFFER_MB -DSMALL_TRANSLATION_CACHE"
export ASFLAGS="-march=armv6 -marm"
make -s -j"$(nproc)" platform=unix CC=$X-gcc CXX=$X-g++ AR=$X-ar \
     CPU_ARCH=arm HAVE_DYNAREC=1 STATIC_LINKING=1 TARGET=libgpsp.a

cp /port/gba_snom.c /snd/snd_hal.h /snd/snd_hal.c /src/
$X-gcc -O2 -march=armv6 -marm -I/src -I/src/libretro/libretro-common/include \
    -c snd_hal.c -o snd_hal.o
$X-gcc -O2 -march=armv6 -marm -I/src -I/src/libretro/libretro-common/include \
    -c gba_snom.c -o gba_snom.o
$X-gcc -static -o /out/gpsp gba_snom.o snd_hal.o libgpsp.a -lm -lpthread
$X-strip /out/gpsp
file /out/gpsp
'
echo "built: $OUT/gpsp"
