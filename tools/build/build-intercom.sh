#!/usr/bin/env bash
# Cross-build micstream (intercom, docs/intercom.md) and spkstream (network speaker,
# docs/speaker.md). Output: out/{micstream,spkstream}, shipped in /snom/cfw/intercom.
# Needs docker.
. "$(dirname "$0")/lib.sh"
musl_run -v "$ROOT/src/audio/intercom":/src:ro '
F="-O2 -Wall -march=armv6 -marm -msoft-float -static -no-pie"
$X-gcc $F -o /out/micstream /src/micstream.c
$X-gcc $F -o /out/spkstream /src/spkstream.c -lpthread
$X-strip /out/micstream /out/spkstream
file /out/micstream /out/spkstream'
ship micstream spkstream "$CFW/intercom"
