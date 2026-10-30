#!/usr/bin/env bash
# Cross-build a tiny static musl armv6 `unzip` (busybox 1.36.1 with ONLY the
# unzip applet) -> tools/out/unzip, shipped as /snom/cfw/bin/unzip.
# The phone's own busybox has no unzip applet. Needs docker. See docs/zip.md.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/out"; mkdir -p "$OUT"
docker run --rm -v "$OUT":/out debian:bookworm-slim bash -euo pipefail -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wget xz-utils bzip2 make gcc libc6-dev file ca-certificates >/dev/null
cd /opt
wget -q https://musl.cc/arm-linux-musleabi-cross.tgz
tar xf arm-linux-musleabi-cross.tgz
export PATH=/opt/arm-linux-musleabi-cross/bin:$PATH
wget -q https://busybox.net/downloads/busybox-1.36.1.tar.bz2
tar xf busybox-1.36.1.tar.bz2
cd busybox-1.36.1
make allnoconfig >/dev/null
for kv in STATIC=y CROSS_COMPILER_PREFIX=\"arm-linux-musleabi-\" EXTRA_CFLAGS=\"-march=armv6\ -marm\ -Os\" \
          UNZIP=y FEATURE_UNZIP_CDF=y LFS=y; do
    k=${kv%%=*}
    sed -i "/^# CONFIG_$k is not set/d; /^CONFIG_$k=/d" .config
    echo "CONFIG_$kv" >> .config
done
make oldconfig </dev/null >/dev/null || true
make -j4 busybox 2>&1 | tail -20
arm-linux-musleabi-strip busybox
cp busybox /out/unzip
file /out/unzip
'
echo "built: $OUT/unzip (run as 'unzip'; busybox dispatches on argv[0])"
