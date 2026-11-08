#!/usr/bin/env bash
# Build out/fb24shim.so for the D375's glibc 2.19. Needs docker.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
docker run --rm -v "$ROOT/src/native":/t:ro -v "$ROOT/out":/o debian/eol:stretch bash -euo pipefail -c '
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq gcc-arm-linux-gnueabi linux-libc-dev-armel-cross >/dev/null 2>&1
arm-linux-gnueabi-gcc -shared -fPIC -Os -Wall -march=armv5te -marm -D_FILE_OFFSET_BITS=32 -I/t \
    -o /o/fb24shim.so /t/fb24shim.c -ldl -lpthread
arm-linux-gnueabi-strip /o/fb24shim.so
arm-linux-gnueabi-readelf -V /o/fb24shim.so | grep -o "GLIBC_[0-9.]*" | sort -Vu | tail -1
chown '"$(id -u):$(id -g)"' /o/fb24shim.so'
ls -la "$ROOT/out/fb24shim.so"
