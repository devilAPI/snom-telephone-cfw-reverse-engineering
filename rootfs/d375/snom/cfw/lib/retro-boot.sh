#!/bin/sh
# retro-boot.sh SYS URL | SYS --pick SID IDX - launcher for the emulators.
#   SYS = gba (gpSP) | gb (gambatte, GB + GBC) | nes (InfoNES)
# Downloads the ROM to RAM (/tmp), checks that it really is a ROM for SYS, runs
# the emulator on the phone screen, then brings the phone app back. Only the URL
# history is stored. A .zip is unpacked (lib/zip.sh, docs/zip.md); with several
# ROMs inside, --pick SID IDX later starts the chosen one. Status and log: see
# lib/game.sh. Called via <sys>/boot-<sys>.sh. See docs/gba.md, gb.md, nes.md.

SYS=$1 URL=$2
case "$SYS" in   # engine, largest download, history dir
    gba) ENGINE=/snom/cfw/gba/gpsp    MAXB=33554432 HIST= ;;  # 32 MiB: largest GBA ROM
    gb)  ENGINE=/snom/cfw/gb/gambatte MAXB=8388608  HIST= ;;  # 8 MiB: largest GB/GBC ROM
    nes) ENGINE=/snom/cfw/nes/infones MAXB=16777216 HIST=/snom/cfw/nes ;;
    *)   echo "usage: $0 gba|gb|nes URL | gba|gb|nes --pick SID IDX" >&2; exit 1 ;;
esac
ROM=/tmp/game.$SYS
. /snom/cfw/lib/game.sh

game_start "$ENGINE"
if [ "$URL" = --pick ]; then
    game_pick "$3" "$4"
else
    # NES also takes file:// (tests/restore.sh); the CGIs only pass http(s).
    case "$SYS:$URL" in nes:*|*:http://*|*:https://*) ;; *) fail "not an http:// or https:// URL" ;; esac
    game_fetch "$URL" "$MAXB"
fi

# Header sanity, so a web page or a ROM for the wrong system never takes over the
# screen. busybox od has no -t here, so compare raw bytes (none is NUL or \n):
#   GBA: fixed value 0x96 at 0xB2 (checked by the real BIOS too)
#   GB:  first 4 bytes of the Nintendo logo at 0x104 (CE ED 66 66)
#   NES: iNES files start with "NES" 0x1a
bytesat() { dd if="$ROM" bs=1 skip="$1" count="$2" 2>/dev/null; }
SIZE=$(wc -c < "$ROM")
case "$SYS" in
    gba) [ "$SIZE" -ge 192 ] && [ "$(bytesat 178 1)" = "$(printf '\226')" ] ||
             fail "not a GBA ROM (no 0x96 at header offset 0xB2)" ;;
    gb)  [ "$SIZE" -ge 336 ] && [ "$(bytesat 260 4)" = "$(printf '\316\355ff')" ] ||
             fail "not a GB/GBC ROM (no Nintendo logo at 0x104)" ;;
    nes) [ "$(bytesat 0 3)" = NES ] || fail "not an iNES ROM" ;;
esac
log "ROM ok: $SIZE bytes"

if D=${HIST:-$(cfw_data_dir "$SYS")}; then
    game_history "$D" "$URL"
else
    log "warning: /snom/cfw-data/$SYS not writable, history not saved"
fi
saves_setup "$SYS" "$ROM"
game_run "$ENGINE" "$ROM"
