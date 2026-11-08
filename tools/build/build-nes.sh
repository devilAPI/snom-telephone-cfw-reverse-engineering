#!/usr/bin/env bash
# Cross-build the InfoNES NES emulator with the snom fb/evdev/snd_hal port.
# Output: out/infones. Needs docker. See docs/nes.md.
. "$(dirname "$0")/lib.sh"
musl_run -v "$ROOT/src/games/nes":/port -v "$ROOT/src/audio/snd":/snd '
git clone --depth 1 https://github.com/jay-kumogata/InfoNES.git /src >/dev/null 2>&1
cp /port/InfoNES_System_snom.cpp /src/src/
cp /snd/snd_hal.h /snd/snd_hal.c /snd/snom_save.h /snd/cfw_keymap.h /src/src/
cd /src/src
# APU at 22050 Hz instead of 44100: half the per-sample APU work; the codec runs
# at 16 kHz anyway (snd_hal box-filters down).
sed -i "s/^#define pAPU_QUALITY 3/#define pAPU_QUALITY 2/" InfoNES_pAPU.h
grep -q "^#define pAPU_QUALITY 2" InfoNES_pAPU.h
F="-O2 -march=armv6 -marm -fomit-frame-pointer"
# snd_hal.c is C: compile it with the C compiler, link everything with g++.
$X-gcc $F -I. -c snd_hal.c -o snd_hal.o
$X-g++ $F -fsigned-char -Wno-write-strings -I. -static -o /out/infones \
    K6502.cpp InfoNES.cpp InfoNES_Mapper.cpp InfoNES_pAPU.cpp InfoNES_System_snom.cpp \
    snd_hal.o -lm -lpthread
$X-strip /out/infones
file /out/infones'
