#!/usr/bin/env bash
# Cross-build cfw-src/bindmount.c as a static musl armv6 binary (needs docker).
# Output: tools/out/bindmount and custom-rootfs/snom/cfw/bin/bindmount. See docs/theming.md.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
OUT="$HERE/out"; mkdir -p "$OUT" "$ROOT/custom-rootfs/snom/cfw/bin"

docker run --rm -v "$ROOT/cfw-src":/src -v "$OUT":/out debian:bookworm-slim bash -euo pipefail -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wget xz-utils ca-certificates file >/dev/null
cd /opt
wget -q https://musl.cc/arm-linux-musleabi-cross.tgz
tar xf arm-linux-musleabi-cross.tgz
export PATH=/opt/arm-linux-musleabi-cross/bin:$PATH
arm-linux-musleabi-gcc -O2 -march=armv6 -marm -static -Wall -o /out/bindmount /src/bindmount.c
arm-linux-musleabi-strip /out/bindmount
file /out/bindmount
'
cp "$OUT/bindmount" "$ROOT/custom-rootfs/snom/cfw/bin/"
echo "built: $OUT/bindmount"
