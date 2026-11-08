#!/usr/bin/env bash
# Build the D815 emulator overlay UBIFS from emu/d815-overlay. Needs docker.
#   qemu-mkoverlay.sh <output.ubifs>
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(realpath -m "$1")
docker run --rm -v "$ROOT/emu/d815-overlay":/in:ro -v "$(dirname "$OUT")":/out \
    debian:bookworm-slim bash -euo pipefail -c "
apt-get update -qq >/dev/null
apt-get install -y -qq mtd-utils >/dev/null
cp -a /in /tmp/ov
chown -R 0:0 /tmp/ov
mkfs.ubifs -r /tmp/ov -m 2048 -e 126976 -c 380 -o /out/$(basename "$OUT")
chown $(id -u):$(id -g) /out/$(basename "$OUT")"
