#!/usr/bin/env bash
# Unpack a snom v10 firmware image: verify -> recover AES passphrase -> decrypt -> extract.
# Mirrors the phone's own verifySoftwareUpdateFile() sequence.
# Image layout:  sig(128) || keyblock(128) || openssl-salted AES-128-CBC(tar.gz)
# (RSA-1024 / SHA-1; same scheme across the snom D1xx/D3xx/D7xx/D8xx v10 line,
#  but firmware1.pub is PER MODEL/LINE -- a D7xx key will NOT open a D3xx image.)
#
#   ./fw-unpack.sh <firmware.bin> <firmware1.pub> [outdir]
#
# Source of the scheme: encrypted.at D785 write-up + forum.coredump.ch/t/235.
set -euo pipefail
IN=${1:?firmware .bin}; PUB=${2:?firmware1.pub (RSA-1024, matching this model)}; OUT=${3:-rootfs}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# 1) signature = first 128 bytes; body = everything after it
dd if="$IN" bs=128 count=1 of="$tmp/sig" 2>/dev/null
if dd if="$IN" bs=128 skip=1 2>/dev/null \
   | openssl dgst -sha1 -verify "$PUB" -signature "$tmp/sig" >/dev/null 2>&1; then
  echo "[ok] signature verified -- this key matches this image"
else
  echo "[warn] signature did NOT verify (wrong key for this model?) -- continuing" >&2
fi

# 2) key block = bytes 128..256; RSA verify-recover yields the AES passphrase
dd if="$IN" bs=128 skip=1 count=1 2>/dev/null \
  | openssl pkeyutl -verifyrecover -pubin -inkey "$PUB" -out "$tmp/key"
echo "[ok] recovered passphrase (len $(wc -c <"$tmp/key"))"

# 3) payload = bytes 256..EOF; openssl-salted AES-128-CBC, MD5 KDF
dd if="$IN" bs=128 skip=2 2>/dev/null \
  | openssl enc -aes-128-cbc -d -md md5 -kfile "$tmp/key" > "$tmp/rootfs.tar.gz"
echo "[ok] decrypted -> rootfs.tar.gz ($(wc -c <"$tmp/rootfs.tar.gz") bytes)"

mkdir -p "$OUT"
if command -v fakeroot >/dev/null 2>&1; then
  fakeroot -s "$OUT/.fakeroot" tar -xzf "$tmp/rootfs.tar.gz" -C "$OUT" --numeric-owner
else
  echo "[warn] fakeroot not installed; extracting without it (dev nodes/owners lost)" >&2
  tar -xzf "$tmp/rootfs.tar.gz" -C "$OUT" --numeric-owner
fi
echo "[done] unpacked -> $OUT"
