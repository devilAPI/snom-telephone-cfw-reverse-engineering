#!/bin/sh
# retro-boot.sh SYS URL - shared launcher for the libretro emulators.
#   SYS = gba (gpSP) | gb (gambatte, GB + GBC)
# Downloads the ROM to RAM (/tmp), checks that it really is a ROM for SYS,
# takes over the screen (the engine kills lid + media_daemon itself after
# arming the loudspeaker, see snd/snd_hal.c), runs the emulator, then brings
# the phone app back. Nothing is stored except the URL history.
#
# Progress for the CGIs goes to /tmp/SYS.status, one word + message:
#   downloading | error <message> | running | done
# The full log is /tmp/SYS.log. Called via gba/boot-gba.sh and gb/boot-gb.sh.
# See docs/gba.md and docs/gb.md.

SYS=$1
URL=$2
case "$SYS" in
    gba) ENGINE=/snom/cfw/gba/gpsp;     MAXB=33554432 ;;  # 32 MiB: largest GBA ROM
    gb)  ENGINE=/snom/cfw/gb/gambatte;  MAXB=8388608  ;;  # 8 MiB: largest GB/GBC ROM
    *)   echo "usage: $0 gba|gb URL" >&2; exit 1 ;;
esac
ROM=/tmp/game.$SYS
LOG=/tmp/$SYS.log
STATUS=/tmp/$SYS.status

# We may be started from a CGI: keep cfw.sh from reading a POST body.
unset REQUEST_METHOD CONTENT_LENGTH QUERY_STRING
. /snom/cfw/lib/cfw.sh

status() { printf '%s\n' "$*" > "$STATUS"; }
fail() { echo "error: $*" >> "$LOG"; status "error $*"; rm -f "$ROM"; exit 1; }

: > "$LOG"
status downloading
[ -x "$ENGINE" ] || fail "emulator engine $ENGINE is missing"
case "$URL" in http://*|https://*) ;; *) fail "not an http:// or https:// URL" ;; esac
if cfw_game_running; then fail "another game is running"; fi

rm -f "$ROM"
echo "downloading $URL" >> "$LOG"
# -f: HTTP errors fail; --max-filesize keeps an endless/huge download out of /tmp.
if ! curl -fkL --connect-timeout 15 --max-time 300 --max-filesize "$MAXB" \
        -o "$ROM" -- "$URL" >>"$LOG" 2>&1; then
    fail "download failed (bad URL, unreachable, or larger than $((MAXB / 1048576)) MiB)"
fi

# Header sanity, so a web page or a ROM for the wrong system never takes over
# the screen:
#   GBA: fixed value 0x96 at 0xB2 (checked by the real BIOS too)
#   GB:  first 4 bytes of the Nintendo logo at 0x104 (CE ED 66 66)
# (busybox od has no -t here, so compare raw bytes; none of them is NUL or \n.)
bytesat() { dd if="$ROM" bs=1 skip="$1" count="$2" 2>/dev/null; }
SIZE=$(wc -c < "$ROM")
case "$SYS" in
    gba) [ "$SIZE" -ge 192 ] && [ "$(bytesat 178 1)" = "$(printf '\226')" ] ||
             fail "not a GBA ROM (no 0x96 at header offset 0xB2)" ;;
    gb)  [ "$SIZE" -ge 336 ] && [ "$(bytesat 260 4)" = "$(printf '\316\355ff')" ] ||
             fail "not a GB/GBC ROM (no Nintendo logo at 0x104)" ;;
esac
echo "ROM ok: $SIZE bytes" >> "$LOG"

# Remember this URL for the phone's Settings -> Games menu (newest first, no
# duplicates, at most 8). A read-only/full flash only loses the history.
if D=$(cfw_data_dir "$SYS"); then
    H=$D/history
    { printf '%s\n' "$URL"; grep -vxF -- "$URL" "$H" 2>/dev/null; } | head -n 8 > "$H.new" &&
        mv "$H.new" "$H" || { rm -f "$H.new"; echo "warning: cannot write $H" >> "$LOG"; }
else
    echo "warning: /snom/cfw-data/$SYS not writable, history not saved" >> "$LOG"
fi

# Hold rcS's fast-update guard so killing the phone app doesn't reboot us.
touch /tmp/ssh_fast_update
status running
"$ENGINE" "$ROM" >> "$LOG" 2>&1 < /dev/null
RC=$?
rm -f "$ROM"
echo "engine exit $RC" >> "$LOG"

if [ "$RC" = 2 ]; then
    # The core refused the ROM before the takeover: the phone app is untouched.
    rm -f /tmp/ssh_fast_update
    status "error the emulator could not load this ROM (see /tmp/$SYS.log)"
    exit 1
fi
status done
# Bring the phone app back (Task D: without a reboot when possible).
[ -x /snom/cfw/lib/phone-restore.sh ] && /snom/cfw/lib/phone-restore.sh || { rm -f /tmp/ssh_fast_update; sync; reboot; }
