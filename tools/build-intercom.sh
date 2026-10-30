#!/usr/bin/env bash
# Cross-build micstream (intercom / baby monitor, see docs/intercom.md) as a static
# musl armv6 soft-float binary. Needs docker. Output: tools/out/micstream, copied to
# custom-rootfs/snom/cfw/intercom/micstream.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
OUT="$HERE/out"; mkdir -p "$OUT"

docker run --rm \
  -v "$ROOT/intercom-src":/src:ro \
  -v "$OUT":/out \
  debian:bookworm-slim bash -euo pipefail -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wget ca-certificates file >/dev/null
cd /opt
wget -q https://musl.cc/arm-linux-musleabi-cross.tgz
tar xf arm-linux-musleabi-cross.tgz
export PATH=/opt/arm-linux-musleabi-cross/bin:$PATH
arm-linux-musleabi-gcc -O2 -Wall -march=armv6 -marm -msoft-float -static -no-pie \
    -o /out/micstream /src/micstream.c
arm-linux-musleabi-strip /out/micstream
file /out/micstream
'
mkdir -p "$ROOT/custom-rootfs/snom/cfw/intercom"
cp "$OUT/micstream" "$ROOT/custom-rootfs/snom/cfw/intercom/micstream"
chmod 755 "$ROOT/custom-rootfs/snom/cfw/intercom/micstream"
echo "built: $OUT/micstream"
