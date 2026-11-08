#!/usr/bin/env bash
# Cross-build src/remote/keyinject.c and fbshot.c as a static musl armv6 binary (needs docker).
# Output: out/{keyinject,fbshot} (and rootfs/d375/snom/cfw/bin/keyinject). See docs/remote.md.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/out"; mkdir -p "$OUT" "$ROOT/rootfs/d375/snom/cfw/bin"

docker run --rm -v "$ROOT/src/remote":/src -v "$OUT":/out debian:bookworm-slim bash -euo pipefail -c '
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
cp "$OUT/keyinject" "$OUT/fbshot" "$ROOT/rootfs/d375/snom/cfw/bin/"
echo "built: $OUT/keyinject"
