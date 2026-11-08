#!/usr/bin/env bash
# Cross-build src/native/rtcap.c (digital audio-output capture for ringtone tests) as a static
# musl armv6 binary. Needs docker. Output: out/rtcap. See docs/ringtones.md.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/out"; mkdir -p "$OUT"
docker run --rm -v "$ROOT/src/native":/src -v "$OUT":/out debian:bookworm-slim bash -euo pipefail -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq wget ca-certificates file >/dev/null
cd /opt && wget -q https://musl.cc/arm-linux-musleabi-cross.tgz && tar xf arm-linux-musleabi-cross.tgz
export PATH=/opt/arm-linux-musleabi-cross/bin:$PATH
arm-linux-musleabi-gcc -O2 -march=armv6 -marm -msoft-float -static -no-pie -Wall -o /out/rtcap /src/rtcap.c
arm-linux-musleabi-strip /out/rtcap
file /out/rtcap
'
echo "built: $OUT/rtcap"
