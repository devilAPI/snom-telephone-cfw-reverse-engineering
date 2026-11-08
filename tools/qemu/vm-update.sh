#!/usr/bin/env bash
# Put a firmware build into the emulator's boot files. See docs/qemu.md.
#
#   tools/qemu/vm-update.sh d375 [firmware.bin]    default: the latest CFW .bin
#   tools/qemu/vm-update.sh d815 [rootfs.ubifs]    default: the latest CFW .ubifs
#
# Output goes to emu/vm/<model>/ under fixed names, so the virt-manager VMs need
# no change: the next boot runs the new build. The flash image is replaced, so
# anything changed inside the guest is lost. A running VM keeps its old flash
# until it is shut down.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MODEL=${1:?usage: vm-update.sh d375|d815 [image]}
IMG=${2:-}
VM="$ROOT/emu/vm/$MODEL"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$VM"

case "$MODEL" in
d375)
    IMG=${IMG:-$ROOT/firmware/custom/snomD375-10.1.64.17-SIP-r.bin}
    head -c 128 "$IMG" > "$tmp/sig"
    tail -c +129 "$IMG" > "$tmp/body"
    good=
    for k in ${VM_KEY:-} "$ROOT/keys/custom-d375/firmware.pub" "$ROOT/keys/stock/snomD375-firmware1.pub"; do
        if [ -f "$k" ] && openssl dgst -sha1 -verify "$k" -signature "$tmp/sig" \
                "$tmp/body" >/dev/null 2>&1; then
            good=$k; break
        fi
    done
    [ -n "$good" ] || { echo "no key verifies $IMG (set VM_KEY)" >&2; exit 1; }
    head -c 128 "$tmp/body" | openssl pkeyutl -verifyrecover -pubin -inkey "$good" -out "$tmp/pass"
    tail -c +129 "$tmp/body" | openssl enc -aes-128-cbc -d -md md5 -kfile "$tmp/pass" \
        -out "$tmp/rootfs.tar.gz" 2>/dev/null
    tar xzOf "$tmp/rootfs.tar.gz" --wildcards '*boot/uImage' > "$tmp/uImage"
    python3 "$ROOT/tools/qemu/qemu-mkflash.py" "$tmp/rootfs.tar.gz" "$tmp/nand.img"
    mv "$tmp/uImage" "$VM/uImage"
    ;;
d815)
    IMG=${IMG:-$ROOT/firmware/custom/snomD815-rootfs2.ubifs}
    BOOT="$ROOT/rootfs/d815/boot"
    tail -c +65 "$BOOT/uImage" > "$tmp/zImage"
    cp "$BOOT/dvf99-snomD815.dtb" "$tmp/phone.dtb"
    # Hardware with no model is switched off the way the vendor does it.
    fdtput -t s "$tmp/phone.dtb" /gpu@00600000 status disabled
    fdtput -t s "$tmp/phone.dtb" /dvf9a status disabled
    fdtput -t s "$tmp/phone.dtb" /dsa@0 status disabled
    fdtput -t bx "$tmp/phone.dtb" /ethernet@06e00000 mac-address 00 04 13 00 08 15
    if [ ! -f "$VM/overlay.ubifs" ] || \
       [ -n "$(find "$ROOT/emu/d815-overlay" -newer "$VM/overlay.ubifs" -print -quit)" ]; then
        "$ROOT/tools/qemu/qemu-mkoverlay.sh" "$VM/overlay.ubifs"
    fi
    python3 "$ROOT/tools/qemu/qemu-mkubi.py" "$IMG" "$tmp/nand.img" --overlay "$VM/overlay.ubifs"
    mv "$tmp/zImage" "$VM/zImage"
    mv "$tmp/phone.dtb" "$VM/phone.dtb"
    ;;
*)
    echo "unknown model: $MODEL" >&2; exit 2 ;;
esac
mv "$tmp/nand.img" "$VM/nand.img"
sha256sum "$IMG" | cut -c1-12 > "$VM/image.id"
echo "$MODEL now boots $(basename "$IMG") ($(cat "$VM/image.id"))"
