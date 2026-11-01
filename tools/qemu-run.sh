#!/usr/bin/env bash
# Boot a phone model in QEMU, outside libvirt. See docs/qemu.md.
#
#   tools/qemu-run.sh [--headless] d375|d815
#
# Runs what tools/vm-update.sh last prepared, building that on first use.
# Serial console on stdout. Sockets in emu/run/<model>/: monitor.sock, shell.sock
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DISPLAY_ARG=gtk
[ "${1:-}" = --headless ] && { DISPLAY_ARG="vnc=127.0.0.1:75"; shift; }
MODEL=${1:?usage: qemu-run.sh [--headless] d375|d815}
VM="$ROOT/emu/vm/$MODEL"
RUN="$ROOT/emu/run/$MODEL"
QEMU="$ROOT/emu/build/qemu-system-arm"

[ -x "$QEMU" ] || "$ROOT/tools/build-qemu.sh"
[ -f "$VM/nand.img" ] || "$ROOT/tools/vm-update.sh" "$MODEL"
mkdir -p "$RUN"
rm -f "$RUN/monitor.sock" "$RUN/shell.sock"

source "$ROOT/tools/qemu-args.sh"
exec "$QEMU" -display "$DISPLAY_ARG" "${MACHINE_ARGS[@]}" -nic "$NIC" \
    -drive "if=mtd,format=raw,file=$VM/nand.img" -append "$CMDLINE" \
    -serial stdio -serial "unix:$RUN/shell.sock,server,nowait" \
    -monitor "unix:$RUN/monitor.sock,server,nowait"
