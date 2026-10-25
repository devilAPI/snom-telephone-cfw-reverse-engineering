#!/usr/bin/env bash
# Cross-build tinyalsa's command-line tools (tinymix, tinyplay, tinycap,
# tinypcminfo) as static musl armv6 binaries for the snom D375. Needs docker.
# Output: tools/out/tiny*. These are discovery tools; the game ports vendor
# tinyalsa's pcm.c/mixer.c directly for in-game audio. See docs/sound.md.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/out"; mkdir -p "$OUT"

docker run --rm -v "$OUT":/out debian:bookworm-slim bash -euo pipefail -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git wget xz-utils ca-certificates file make >/dev/null
cd /opt
wget -q https://musl.cc/arm-linux-musleabi-cross.tgz
tar xf arm-linux-musleabi-cross.tgz
export PATH=/opt/arm-linux-musleabi-cross/bin:$PATH
CC=arm-linux-musleabi-gcc

git clone --depth 1 https://github.com/tinyalsa/tinyalsa.git /src >/dev/null 2>&1
cd /src
# tinyalsa has no armv6 assumptions; build the lib objects + each tool static.
INC="-Iinclude"
CFLAGS="-O2 -march=armv4t -fomit-frame-pointer $INC"
LIBOBJ=""
for c in src/*.c; do
  o="$(basename "${c%.c}").o"
  $CC $CFLAGS -c "$c" -o "$o"
  LIBOBJ="$LIBOBJ $o"
done
for t in tinymix tinyplay tinycap tinypcminfo; do
  src="utils/$t.c"
  [ -f "$src" ] || src="$t.c"
  $CC $CFLAGS -static -Wl,--gc-sections "$src" $LIBOBJ -o /out/$t -lm -ldl 2>/dev/null \
    || $CC $CFLAGS -static -Wl,--gc-sections "$src" $LIBOBJ -o /out/$t -lm
  arm-linux-musleabi-strip /out/$t
  echo "built $t"
done
file /out/tinymix
'
echo "built into $OUT: tinymix tinyplay tinycap tinypcminfo"
