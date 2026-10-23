#!/usr/bin/env bash
# Build a custom D375 firmware image from the modified rootfs.
# Run from the project root:  ./tools/build-custom-firmware.sh
set -euo pipefail

ROOTFS="custom-rootfs"
KEYDIR="custom-key"
OUT="custom-firmware/snomD375-custom-SIP-r.bin"

echo "=== Step 1: Generate signing keypair (if not already done) ==="
mkdir -p "$KEYDIR"
if [ ! -f "$KEYDIR/firmware.priv.pem" ]; then
    openssl genrsa -out "$KEYDIR/firmware.priv.pem" 1024 2>/dev/null
    openssl rsa -in "$KEYDIR/firmware.priv.pem" -pubout -out "$KEYDIR/firmware.pub" 2>/dev/null
    echo "  Generated new keypair in $KEYDIR/"
else
    echo "  Using existing keypair in $KEYDIR/"
fi

echo "=== Step 2: Create rootfs tarball ==="
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Use fakeroot if available (preserves dev nodes / ownership)
TARLIST=$(cd "$ROOTFS" && find . -mindepth 1 ! -name .fakeroot -print | sed 's|^\./||' | LC_ALL=C sort)
if command -v fakeroot >/dev/null 2>&1 && [ -f "$ROOTFS/.fakeroot" ]; then
    echo "$TARLIST" | fakeroot -i "$ROOTFS/.fakeroot" \
        tar -czf "$tmp/rootfs.tar.gz" -C "$ROOTFS" --numeric-owner \
        --no-recursion -T -
else
    echo "$TARLIST" | \
        tar -czf "$tmp/rootfs.tar.gz" -C "$ROOTFS" --numeric-owner \
        --no-recursion -T -
    echo "  (warning: no fakeroot — dev nodes and ownership may not be exact)"
fi
echo "  rootfs.tar.gz: $(stat -c%s "$tmp/rootfs.tar.gz") bytes"

echo "=== Step 3: Encrypt (AES-128-CBC, MD5 KDF, salted) ==="
# Random passphrase — no trailing newline
openssl rand -base64 32 | tr -d '\n' > "$tmp/pass"
openssl enc -aes-128-cbc -e -md md5 -kfile "$tmp/pass" \
    -in "$tmp/rootfs.tar.gz" -out "$tmp/enc"
echo "  encrypted payload: $(stat -c%s "$tmp/enc") bytes"

echo "=== Step 4: RSA-sign the passphrase (key block) ==="
openssl pkeyutl -sign -inkey "$KEYDIR/firmware.priv.pem" \
    -in "$tmp/pass" -out "$tmp/keyblk"

echo "=== Step 5: Build body and sign it ==="
cat "$tmp/keyblk" "$tmp/enc" > "$tmp/body"
openssl dgst -sha1 -sign "$KEYDIR/firmware.priv.pem" \
    -out "$tmp/sig" "$tmp/body"

# Sanity check: both RSA blocks must be 128 bytes for 1024-bit key
[ "$(wc -c < "$tmp/keyblk")" -eq 128 ] || { echo "FAIL: keyblk not 128 bytes"; exit 1; }
[ "$(wc -c < "$tmp/sig")" -eq 128 ]    || { echo "FAIL: sig not 128 bytes"; exit 1; }

echo "=== Step 6: Assemble final image ==="
mkdir -p "$(dirname "$OUT")"
cat "$tmp/sig" "$tmp/body" > "$OUT"
echo "  wrote $OUT ($(stat -c%s "$OUT") bytes)"

echo ""
echo "=== Step 7: Verify the image decrypts correctly ==="
tmp2=$(mktemp -d)
dd if="$OUT" bs=128 skip=1 count=1 2>/dev/null \
    | openssl pkeyutl -verifyrecover -pubin -inkey "$KEYDIR/firmware.pub" -out "$tmp2/key" 2>/dev/null
dd if="$OUT" bs=128 skip=2 2>/dev/null \
    | openssl enc -aes-128-cbc -d -md md5 -kfile "$tmp2/key" 2>/dev/null \
    | gzip -t && echo "  VERIFIED: image decrypts to valid gzip ✓" \
    || echo "  WARNING: verification failed"
rm -rf "$tmp2"

echo ""
echo "========================================="
echo " DONE. Custom firmware: $OUT"
echo ""
echo " Before flashing, install the custom public key on the phone:"
echo "   scp $KEYDIR/firmware.pub root@<phone-ip>:/tmp/firmware1.pub.new"
echo "   ssh root@<phone-ip>"
echo "   mount -o remount,rw /"
echo "   cp /tmp/firmware1.pub.new /firmware1.pub"
echo "   # Update checksum:"
echo "   NEWHASH=\$(md5sum /firmware1.pub | cut -d' ' -f1)"
echo "   awk -v h=\"\$NEWHASH\" '{ if (\$2==\"firmware1.pub\") print h\"  firmware1.pub\"; else print }' /etc/checksum.md5 > /tmp/checksum.md5.new"
echo "   cp /tmp/checksum.md5.new /etc/checksum.md5"
echo "   sync"
echo "   mount -o remount,ro /"
echo ""
echo " Then flash via the phone web UI: Software Update → URL → $OUT"
echo " Or serve it over HTTP and point the phone to it."
echo "========================================="
