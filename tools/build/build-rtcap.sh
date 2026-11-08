#!/usr/bin/env bash
# Cross-build src/native/rtcap.c (digital audio-output capture for ringtone tests).
# Output: out/rtcap. Needs docker. See docs/ringtones.md.
. "$(dirname "$0")/lib.sh"
musl_run -v "$ROOT/src/native":/src '
$X-gcc -O2 -march=armv6 -marm -msoft-float -static -no-pie -Wall -o /out/rtcap /src/rtcap.c
$X-strip /out/rtcap
file /out/rtcap'
