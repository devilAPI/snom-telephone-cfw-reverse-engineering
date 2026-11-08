#!/usr/bin/env bash
# Cross-build a tiny `unzip`: busybox 1.36.1 with only the unzip applet (the phone's
# busybox has none). Output: out/unzip, shipped as /snom/cfw/bin/unzip. Needs docker.
# See docs/zip.md.
. "$(dirname "$0")/lib.sh"
PKGS="gcc libc6-dev" musl_run '
wget -q https://busybox.net/downloads/busybox-1.36.1.tar.bz2
tar xf busybox-1.36.1.tar.bz2
cd busybox-1.36.1
make allnoconfig >/dev/null
for kv in STATIC=y CROSS_COMPILER_PREFIX=\"$X-\" EXTRA_CFLAGS=\"-march=armv6\ -marm\ -Os\" \
          UNZIP=y FEATURE_UNZIP_CDF=y LFS=y; do
    k=${kv%%=*}
    sed -i "/^# CONFIG_$k is not set/d; /^CONFIG_$k=/d" .config
    echo "CONFIG_$kv" >> .config
done
make oldconfig </dev/null >/dev/null || true
make -j4 busybox 2>&1 | tail -20
$X-strip busybox
cp busybox /out/unzip
file /out/unzip'
echo "built: $OUT/unzip (run as 'unzip'; busybox dispatches on argv[0])"
