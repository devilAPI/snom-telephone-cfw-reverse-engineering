#!/usr/bin/env bash
# Cross-build src/native/bindmount.c as a static musl armv6 binary (needs docker).
# Output: out/bindmount and rootfs/d375/snom/cfw/bin/bindmount. See docs/theming.md.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/out"; mkdir -p "$OUT" "$ROOT/rootfs/d375/snom/cfw/bin"

docker run --rm -v "$ROOT/src/native":/src -v "$OUT":/out debian:bookworm-slim bash -euo pipefail -c '
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
cp "$OUT/bindmount" "$ROOT/rootfs/d375/snom/cfw/bin/"
echo "built: $OUT/bindmount"
