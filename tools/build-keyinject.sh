#!/usr/bin/env bash
# Cross-build remote-src/keyinject.c and fbshot.c as a static musl armv6 binary (needs docker).
# Output: tools/out/{keyinject,fbshot} (and custom-rootfs/snom/cfw/bin/keyinject). See docs/remote.md.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
OUT="$HERE/out"; mkdir -p "$OUT" "$ROOT/custom-rootfs/snom/cfw/bin"

docker run --rm -v "$ROOT/remote-src":/src -v "$OUT":/out debian:bookworm-slim bash -euo pipefail -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wget xz-utils ca-certificates file >/dev/null
cd /opt
wget -q https://musl.cc/arm-linux-musleabi-cross.tgz
tar xf arm-linux-musleabi-cross.tgz
export PATH=/opt/arm-linux-musleabi-cross/bin:$PATH
arm-linux-musleabi-gcc -O2 -march=armv6 -marm -static -Wall -o /out/keyinject /src/keyinject.c
arm-linux-musleabi-gcc -O2 -march=armv6 -marm -static -Wall -o /out/fbshot /src/fbshot.c
arm-linux-musleabi-strip /out/keyinject /out/fbshot
file /out/keyinject /out/fbshot
'
cp "$OUT/keyinject" "$OUT/fbshot" "$ROOT/custom-rootfs/snom/cfw/bin/"
echo "built: $OUT/keyinject"
