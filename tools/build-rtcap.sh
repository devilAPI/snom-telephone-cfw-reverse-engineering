#!/usr/bin/env bash
# Cross-build tools/rtcap.c (digital audio-output capture for ringtone tests) as a static
# musl armv6 binary. Needs docker. Output: tools/out/rtcap. See docs/ringtones.md.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/out"; mkdir -p "$OUT"
docker run --rm -v "$HERE":/tools -v "$OUT":/out debian:bookworm-slim bash -euo pipefail -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq wget ca-certificates file >/dev/null
cd /opt && wget -q https://musl.cc/arm-linux-musleabi-cross.tgz && tar xf arm-linux-musleabi-cross.tgz
export PATH=/opt/arm-linux-musleabi-cross/bin:$PATH
arm-linux-musleabi-gcc -O2 -march=armv6 -marm -msoft-float -static -no-pie -Wall -o /out/rtcap /tools/rtcap.c
arm-linux-musleabi-strip /out/rtcap
file /out/rtcap
'
echo "built: $OUT/rtcap"
