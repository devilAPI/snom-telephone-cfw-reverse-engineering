#!/usr/bin/env bash
# Cross-build src/remote/keyinject.c and fbshot.c. Output: out/{keyinject,fbshot},
# shipped in /snom/cfw/bin. Needs docker. See docs/remote.md.
. "$(dirname "$0")/lib.sh"
musl_run -v "$ROOT/src/remote":/src '
for b in keyinject fbshot; do
    $X-gcc -O2 -march=armv6 -marm -static -Wall -o /out/$b /src/$b.c
done
$X-strip /out/keyinject /out/fbshot
file /out/keyinject /out/fbshot'
ship keyinject fbshot "$CFW/bin"
