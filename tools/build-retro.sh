#!/usr/bin/env bash
# Cross-build the libretro-based emulators for the snom D375: each core is
# linked statically with the same frontend (retro-src/snom_retro.c) and
# snd/snd_hal.c into one static musl armv6 binary. Needs docker.
#
#   tools/out/gpsp      GBA  (libretro/gpsp, ARM dynarec)
#   tools/out/gambatte  GB/GBC (libretro/gambatte-libretro)
#   tools/out/gearboy   GB/GBC (drhelius/Gearboy) - only with CORES="... gearboy";
#                       measured against gambatte, not shipped (docs/gb.md)
#
# CORES="gpsp gambatte" (default) picks what to build. See docs/gba.md, docs/gb.md.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
OUT="$HERE/out"; mkdir -p "$OUT"

GPSP_COMMIT=5819380c2ffb0900219d700a382ee68c464ebb99       # libretro/gpsp, 2026-09-19
GAMBATTE_COMMIT=7809bb68ee96c3e6c74e9d9c4c8bb09aa7c6801d   # libretro/gambatte-libretro, 2026-10-23
GEARBOY_COMMIT=af215bc8541709c03f7f95a9ebe1f036ecfc5f1a    # drhelius/Gearboy, 2026-10-28
ROM_BUFFER_MB=${ROM_BUFFER_MB:-8}   # gpSP: ROM kept in RAM; larger ROMs page in from the file
CORES=${CORES:-gpsp gambatte}

docker run --rm \
  -e GPSP_COMMIT="$GPSP_COMMIT" -e GAMBATTE_COMMIT="$GAMBATTE_COMMIT" \
  -e GEARBOY_COMMIT="$GEARBOY_COMMIT" -e ROM_BUFFER_MB="$ROM_BUFFER_MB" -e CORES="$CORES" \
  -v "$ROOT/retro-src":/port:ro \
  -v "$ROOT/snd":/snd:ro \
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
# The D375 CPU is an ARM1176 (armv6, no VFP): soft-float, ARM mode.
ARCH="-march=armv6 -marm"

clone() {  # url dir commit
    git init -q "$2" && git -C "$2" remote add origin "$1"
    git -C "$2" fetch -q --depth 1 origin "$3" && git -C "$2" checkout -q FETCH_HEAD
}

# Frontend + snd_hal, once per core (CORE_* selects the option table/tag).
# The libretro.h API header comes from gpSP (stable ABI, all cores agree).
clone https://github.com/libretro/gpsp.git /gpsp "$GPSP_COMMIT"
INC="-I/snd -I/gpsp/libretro/libretro-common/include"
$X-gcc -O2 $ARCH -c /snd/snd_hal.c -o /tmp/snd_hal.o
frontend() { $X-gcc -O2 $ARCH $INC -D"$1" -c /port/snom_retro.c -o /tmp/fe_$2.o; }

for core in $CORES; do
  case $core in
  gpsp)
    cd /gpsp
    CFLAGS="$ARCH -DROM_BUFFER_SIZE=$ROM_BUFFER_MB -DSMALL_TRANSLATION_CACHE" ASFLAGS="$ARCH" \
      make -s -j"$(nproc)" platform=unix CC=$X-gcc CXX=$X-g++ AR=$X-ar \
           CPU_ARCH=arm HAVE_DYNAREC=1 STATIC_LINKING=1 TARGET=libcore.a
    frontend CORE_GPSP gpsp
    $X-gcc -static -o /out/gpsp /tmp/fe_gpsp.o /tmp/snd_hal.o libcore.a -lm -lpthread
    ;;
  gambatte)
    clone https://github.com/libretro/gambatte-libretro.git /gambatte "$GAMBATTE_COMMIT"
    cd /gambatte
    # STATIC_LINKING=1 would leave out libretro-common (a RetroArch build
    # provides it); build the normal way and archive every object instead.
    CFLAGS="$ARCH" CXXFLAGS="$ARCH" \
      make -s -j"$(nproc)" -f Makefile.libretro platform=unix CC=$X-gcc CXX=$X-g++ AR=$X-ar \
           HAVE_NETWORK=0
    $X-ar rcs libcore.a $(find . -name "*.o")
    frontend CORE_GAMBATTE gambatte
    $X-g++ -static -o /out/gambatte /tmp/fe_gambatte.o /tmp/snd_hal.o libcore.a -lm -lpthread
    ;;
  gearboy)
    clone https://github.com/drhelius/Gearboy.git /gearboy "$GEARBOY_COMMIT"
    cd /gearboy/platforms/libretro
    CFLAGS="$ARCH" CXXFLAGS="$ARCH" \
      make -s -j"$(nproc)" platform=unix CC=$X-gcc CXX=$X-g++ AR=$X-ar
    $X-ar rcs libcore.a $(find ../.. -name "*.o")
    frontend CORE_GEARBOY gearboy
    $X-g++ -static -o /out/gearboy /tmp/fe_gearboy.o /tmp/snd_hal.o libcore.a -lm -lpthread
    ;;
  *) echo "unknown core $core"; exit 1 ;;
  esac
  $X-strip /out/$core
  file /out/$core
done
'
for c in $CORES; do echo "built: $OUT/$c"; done
