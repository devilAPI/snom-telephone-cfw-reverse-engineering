#!/usr/bin/env bash
# Build qemu-system-arm with the snom-d375 machine. Output: emu/build/qemu-system-arm
# Needs: gcc, meson, ninja, glib, pixman, libslirp, gtk3 (development files).
# See docs/qemu.md.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VER=11.1.2
SRC="$ROOT/emu/qemu-$VER"
mkdir -p "$ROOT/emu/build"

if [ ! -d "$SRC" ]; then
    tar=$(mktemp --suffix=.tar.xz)
    trap 'rm -f "$tar"' EXIT
    curl -fSL -o "$tar" "https://download.qemu.org/qemu-$VER.tar.xz"
    tar xJf "$tar" -C "$ROOT/emu"
fi

# Add the board to the source tree. The file stays in emu/board/ so it is tracked.
for f in snom_d375.c snom_d815.c snom_common.h; do
    ln -sf "../../../board/$f" "$SRC/hw/arm/$f"
done
sed -i -E "s/if_true: files\('versatilepb.c'(, 'snom_d375.c')?\)\)/if_true: files('versatilepb.c', 'snom_d375.c', 'snom_d815.c'))/" \
    "$SRC/hw/arm/meson.build"

cd "$ROOT/emu/build"
if ! grep -q "enable-fdt" config.status 2>/dev/null; then
    "$SRC/configure" --target-list=arm-softmmu --without-default-features \
        --enable-tcg --enable-slirp --enable-gtk --enable-pixman --enable-vnc \
        --enable-png --enable-fdt=system --disable-werror --disable-docs --disable-tools
fi
ninja qemu-system-arm
echo "built: $ROOT/emu/build/qemu-system-arm"
