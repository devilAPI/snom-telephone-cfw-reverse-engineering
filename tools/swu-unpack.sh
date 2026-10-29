#!/usr/bin/env bash
# Unpack a snom v10 SWU firmware image (D8xx line, SWUpdate format).
# Layout: cpio archive containing sw-description, sw-description.sig, u-boot.bin, <rootfs>.ubifs.enc
# The rootfs is AES-256-CBC encrypted; the key+IV live in /firmware1.aes on the device.
#
#   ./swu-unpack.sh <firmware.swu> <firmware1.aes> [outdir]
#
# firmware1.aes format: <64-char hex key> <32-char hex IV>  (single line, space-separated)
set -euo pipefail
SWU=${1:?firmware .swu}; AES=${2:?firmware1.aes (key+IV file from device)}; OUT=${3:-rootfs}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

read -r KEY IV < "$AES"
echo "[ok] AES key=${KEY:0:8}... IV=${IV:0:8}..."

# 1) extract cpio
(cd "$tmp" && cpio -id < "$SWU" 2>/dev/null)
echo "[ok] extracted cpio: $(ls "$tmp")"

# 2) find encrypted rootfs
ENC=$(find "$tmp" -name '*.ubifs.enc' | head -1)
if [ -z "$ENC" ]; then
  echo "[error] no .ubifs.enc found in SWU" >&2; exit 1
fi
echo "[ok] encrypted rootfs: $(basename "$ENC") ($(wc -c < "$ENC") bytes)"

# 3) decrypt
openssl enc -aes-256-cbc -d -K "$KEY" -iv "$IV" -in "$ENC" -out "$tmp/rootfs.ubifs"
echo "[ok] decrypted -> rootfs.ubifs ($(wc -c < "$tmp/rootfs.ubifs") bytes)"

# 4) extract UBIFS
if command -v ubireader_extract_files >/dev/null 2>&1; then
  UBIREADER=ubireader_extract_files
elif [ -x "${VENV:-}/bin/ubireader_extract_files" ]; then
  UBIREADER="$VENV/bin/ubireader_extract_files"
else
  echo "[warn] ubireader_extract_files not found; leaving rootfs.ubifs for manual extraction" >&2
  mkdir -p "$OUT"
  cp "$tmp/rootfs.ubifs" "$OUT/rootfs.ubifs"
  [ -f "$tmp/u-boot.bin" ] && cp "$tmp/u-boot.bin" "$OUT/"
  [ -f "$tmp/sw-description" ] && cp "$tmp/sw-description" "$OUT/"
  echo "[done] raw files -> $OUT (install ubi_reader to extract the filesystem)"
  exit 0
fi

mkdir -p "$OUT"
"$UBIREADER" -o "$OUT" "$tmp/rootfs.ubifs" 2>&1 | grep -v "DEV Fail" || true
[ -f "$tmp/u-boot.bin" ] && cp "$tmp/u-boot.bin" "$OUT/"
[ -f "$tmp/sw-description" ] && cp "$tmp/sw-description" "$OUT/"
echo "[done] unpacked -> $OUT"
