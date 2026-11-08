#!/usr/bin/env bash
# Build firmware/custom/snomD815-rootfs2.ubifs. Needs docker.
#
# rootfs/d815/ has no owners or execute bits (it was extracted without
# them), so an image made straight from it cannot boot: the kernel gets EACCES
# on /sbin/init. Instead, extract the stock UBIFS as root, which keeps modes,
# and copy over only the files that differ from stock.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SWU="$ROOT/firmware/stock/snomD815-10.1.226.16-SIP-r.swu"
STOCK="$ROOT/rootfs/stock/D815-10.1.226.16"
CFW="$ROOT/rootfs/d815"
OUT="$ROOT/firmware/custom/snomD815-rootfs2.ubifs"
MAX_LEB_CNT=826

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
(cd "$tmp" && cpio -id --quiet '*.ubifs.enc' < "$SWU")
read -r KEY IV < "$ROOT/keys/stock/snomD815-firmware1.aes"
openssl enc -aes-256-cbc -d -K "$KEY" -iv "$IV" \
    -in "$tmp"/*.ubifs.enc -out "$tmp/stock.ubifs"

# Paths that differ, relative to the rootfs. New files are not expected here.
(cd "$CFW" && find . \( -type f -o -type l \) -print0) | while IFS= read -r -d '' f; do
    if [ -L "$CFW/$f" ]; then
        [ "$(readlink "$CFW/$f")" = "$(readlink "$STOCK/$f" 2>/dev/null)" ] || printf '%s\n' "$f"
    elif ! cmp -s "$CFW/$f" "$STOCK/$f"; then
        printf '%s\n' "$f"
    fi
done > "$tmp/changed"
echo "CFW files:"; sed 's/^/  /' "$tmp/changed"

docker run --rm -v "$tmp":/w -v "$CFW":/cfw:ro debian:bookworm-slim bash -euo pipefail -c "
apt-get update -qq >/dev/null
apt-get install -y -qq mtd-utils python3-pip python3-lzo liblzo2-dev >/dev/null 2>&1
pip install -q --break-system-packages ubi_reader >/dev/null 2>&1
ubireader_extract_files -k -o /w/root /w/stock.ubifs >/dev/null
cd /w/root
while IFS= read -r f; do
    if [ -f \"\$f\" ] && [ ! -L \"/cfw/\$f\" ]; then
        cat \"/cfw/\$f\" > \"\$f\"
    else
        mkdir -p \"\$(dirname \"\$f\")\"; cp -a \"/cfw/\$f\" \"\$f\"; chown -h 0:0 \"\$f\"
    fi
done < /w/changed
test -x bin/busybox
mkfs.ubifs -r /w/root -m 2048 -e 126976 -c $MAX_LEB_CNT -o /w/out.ubifs
chown $(id -u):$(id -g) /w/out.ubifs
rm -rf /w/root"

if [ -f "$OUT" ]; then
    mkdir -p "$ROOT/firmware/custom/previous"
    cp -p "$OUT" "$ROOT/firmware/custom/previous/snomD815-rootfs2.$(date -r "$OUT" +%Y%m%d-%H%M%S).ubifs"
fi
mv "$tmp/out.ubifs" "$OUT"
echo "built: $OUT ($(stat -c%s "$OUT") bytes)"
