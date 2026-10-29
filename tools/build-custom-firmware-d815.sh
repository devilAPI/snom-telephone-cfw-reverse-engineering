#!/usr/bin/env bash
# Build a custom D815 firmware image (SWU format) from a modified rootfs.
# Run from the project root:  ./tools/build-custom-firmware-d815.sh
set -euo pipefail

ROOTFS="custom-rootfs-d815"
KEYDIR="custom-key-d815"
OUT="custom-firmware/snomD815-10.1.226.16-cfw1-SIP-r.swu"
VERSION="10.1.226.16-cfw1"

# UBI parameters (from D815W device)
LEB_SIZE=126976    # logical erase block
MIN_IO=2048        # NAND page size
MAX_LEB_CNT=826    # rootfs volume size / LEB size

echo "=== Step 1: Generate signing keypair + AES key (if not already done) ==="
mkdir -p "$KEYDIR"
if [ ! -f "$KEYDIR/firmware.priv.pem" ]; then
    openssl genrsa -out "$KEYDIR/firmware.priv.pem" 2048 2>/dev/null
    openssl rsa -in "$KEYDIR/firmware.priv.pem" -pubout -out "$KEYDIR/firmware.pub" 2>/dev/null
    echo "  Generated new RSA-2048 keypair in $KEYDIR/"
else
    echo "  Using existing keypair in $KEYDIR/"
fi
if [ ! -f "$KEYDIR/firmware.aes" ]; then
    KEY=$(openssl rand -hex 32)
    IV=$(openssl rand -hex 16)
    echo "$KEY $IV" > "$KEYDIR/firmware.aes"
    echo "  Generated new AES-256 key+IV"
else
    echo "  Using existing AES key in $KEYDIR/"
fi

echo "=== Step 1b: Embed our keys in the rootfs ==="
[ -d "$ROOTFS" ] || { echo "FAIL: $ROOTFS/ missing"; exit 1; }
cp "$KEYDIR/firmware.pub" "$ROOTFS/firmware1.pub"
cp "$KEYDIR/firmware.aes" "$ROOTFS/firmware1.aes"
echo "  Updated firmware1.pub and firmware1.aes in rootfs"

echo "=== Step 2: Build UBIFS image ==="
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkfs.ubifs -r "$ROOTFS" -m $MIN_IO -e $LEB_SIZE -c $MAX_LEB_CNT \
    -o "$tmp/snomD815-rootfs2.ubifs" 2>&1
DECRYPTED_SIZE=$(stat -c%s "$tmp/snomD815-rootfs2.ubifs")
echo "  UBIFS image: $DECRYPTED_SIZE bytes"

echo "=== Step 3: Encrypt rootfs (AES-256-CBC) ==="
read -r AES_KEY AES_IV < "$KEYDIR/firmware.aes"
openssl enc -aes-256-cbc -e -K "$AES_KEY" -iv "$AES_IV" \
    -in "$tmp/snomD815-rootfs2.ubifs" \
    -out "$tmp/snomD815-rootfs2.ubifs.enc"
ENC_SHA256=$(sha256sum "$tmp/snomD815-rootfs2.ubifs.enc" | cut -d' ' -f1)
echo "  Encrypted: $(stat -c%s "$tmp/snomD815-rootfs2.ubifs.enc") bytes"

echo "=== Step 4: Prepare u-boot ==="
STOCK_SWU="${STOCK_SWU:-orig_firm/snomD815-10.1.226.16-SIP-r.swu}"
if [ -f "$STOCK_SWU" ]; then
    (cd "$tmp" && cpio -id u-boot.bin < "$(realpath "$STOCK_SWU")" 2>/dev/null)
    echo "  Extracted u-boot.bin from stock SWU"
elif [ -f "$tmp/u-boot.bin" ]; then
    echo "  Using existing u-boot.bin"
else
    echo "FAIL: no u-boot.bin source. Set STOCK_SWU= or place u-boot.bin in build dir" >&2; exit 1
fi
UBOOT_SHA256=$(sha256sum "$tmp/u-boot.bin" | cut -d' ' -f1)

echo "=== Step 5: Create sw-description ==="
cat > "$tmp/sw-description" << SWEOF
software =
{
    version = "$VERSION";
    snomD815:
    {
        hardware-compatibility: [ "1.0", "2.0" ];

        copy1:
        {
            images: (
                {
                    name = "u-boot";
                    filename = "u-boot.bin";
                    mtdname = "uboot";
                    type = "flash";
                    sha256 = "$UBOOT_SHA256";
                    version = "U-Boot_dvf99_master_2012.04.01_(Sep_26_2025_-_14:33:50)_evb99_snomD815";
                    install-if-different = true;
                },
                {
                    name = "rootfs";
                    filename = "snomD815-rootfs2.ubifs.enc";
                    volume = "rootfs1";
                    type = "ubivol";
                    sha256 = "$ENC_SHA256";
                    installed-directly: true;
                    encrypted = true;
                    properties = {decrypted-size = "$DECRYPTED_SIZE";}
                }
            );
            bootenv: (
                { name = "rootfsvol"; value = "rootfs1"; },
                { name = "rootfs1version"; value = "$VERSION"; },
            );
        };

        copy2:
        {
            images: (
                {
                    name = "u-boot";
                    filename = "u-boot.bin";
                    mtdname = "uboot";
                    type = "flash";
                    sha256 = "$UBOOT_SHA256";
                    version = "U-Boot_dvf99_master_2012.04.01_(Sep_26_2025_-_14:33:50)_evb99_snomD815";
                    install-if-different = true;
                },
                {
                    name = "rootfs";
                    filename = "snomD815-rootfs2.ubifs.enc";
                    volume = "rootfs2";
                    type = "ubivol";
                    sha256 = "$ENC_SHA256";
                    installed-directly: true;
                    encrypted = true;
                    properties = {decrypted-size = "$DECRYPTED_SIZE";}
                }
            );
            bootenv: (
                { name = "rootfsvol"; value = "rootfs2"; },
                { name = "rootfs2version"; value = "$VERSION"; },
            );
        };
    };
}
SWEOF

echo "=== Step 6: Sign sw-description ==="
openssl dgst -sha256 -sign "$KEYDIR/firmware.priv.pem" \
    -out "$tmp/sw-description.sig" "$tmp/sw-description"
echo "  Signature: $(wc -c < "$tmp/sw-description.sig") bytes"

echo "=== Step 7: Build SWU (cpio) ==="
mkdir -p "$(dirname "$OUT")"
(cd "$tmp" && echo -e "sw-description\nsw-description.sig\nu-boot.bin\nsnomD815-rootfs2.ubifs.enc" | \
    cpio -o -H crc) > "$OUT" 2>/dev/null
echo "  Wrote $OUT ($(stat -c%s "$OUT") bytes)"

echo ""
echo "========================================="
echo " DONE. Custom firmware: $OUT"
echo ""
echo " Before flashing, install the custom keys on the phone:"
echo "   scp $KEYDIR/firmware.pub root@<phone-ip>:/tmp/cfw-firmware1.pub"
echo "   scp $KEYDIR/firmware.aes root@<phone-ip>:/tmp/cfw-firmware1.aes"
echo ""
echo " Then flash via swupdate on the phone (active slot = copy that's NOT running):"
echo "   wget -O /tmp/firmware.swu http://<your-ip>:8081/$(basename "$OUT")"
echo "   swupdate -v -i /tmp/firmware.swu -e snomD815,copy2 -k /tmp/cfw-firmware1.pub -K /tmp/cfw-firmware1.aes"
echo ""
echo " Or serve it and let the phone pull:"
echo "   cd custom-firmware && python3 -m http.server 8081"
echo "========================================="
