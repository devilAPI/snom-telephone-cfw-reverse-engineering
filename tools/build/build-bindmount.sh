#!/usr/bin/env bash
# Cross-build src/native/bindmount.c. Output: out/bindmount, shipped as
# /snom/cfw/bin/bindmount. Needs docker. See docs/theming.md.
. "$(dirname "$0")/lib.sh"
musl_run -v "$ROOT/src/native":/src '
$X-gcc -O2 -march=armv6 -marm -static -Wall -o /out/bindmount /src/bindmount.c
$X-strip /out/bindmount
file /out/bindmount'
ship bindmount "$CFW/bin"
