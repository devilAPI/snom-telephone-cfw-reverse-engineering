#!/bin/sh
# Boot NES from a URL: download the ROM to RAM, take over the screen, run the
# emulator, then bring the phone app back (phone-restore.sh; reboot only if
# that fails). Nothing is stored. $1 = ROM URL.
# $1 = ROM URL, or "--pick SID IDX" to start entry IDX of a multi-ROM zip that
# an earlier run unpacked (lib/zip.sh, docs/zip.md). Progress for the CGIs goes
# to /tmp/nes.status (downloading | error <msg> | choose <sid> <n> | running).
ENGINE=/snom/cfw/nes/infones
ROM=/tmp/game.nes
LOG=/tmp/nes.log
STATUS=/tmp/nes.status
URL="$1"
. /snom/cfw/lib/zip.sh

: > "$LOG"
status() { printf '%s\n' "$*" > "$STATUS"; }
fail() { echo "error: $*" >> "$LOG"; status "error $*"; rm -f "$ROM"; exit 1; }
status downloading
[ -x "$ENGINE" ] || fail "nes engine missing"
[ -n "$URL" ]    || fail "no URL"

rm -f "$ROM"
if [ "$URL" = --pick ]; then
    zip_pick nes "$2" "$3" || fail "$ZIP_ERR"
    URL=$ZIP_URL
    mv "$ZIP_ROM" "$ROM" || fail "cannot move the chosen file"
    zip_clear nes
    echo "chosen entry $3 of the zip from $URL" >> "$LOG"
else
    zip_clear nes
    if ! curl -fkL --connect-timeout 15 --max-time 180 -o "$ROM" "$URL" >>"$LOG" 2>&1; then
        fail "download failed: $URL"
    fi
    if zip_is_zip "$ROM"; then
        echo "zip archive, unpacking" >> "$LOG"
        zip_extract nes "$ROM" "$(zip_ext nes)" "$URL"
        case $? in
            0) mv "$ZIP_ROM" "$ROM" && zip_clear nes || fail "cannot move the unpacked file" ;;
            2) echo "zip holds $ZIP_N ROMs, waiting for a choice:" >> "$LOG"; cat /tmp/zip-nes/list >> "$LOG"
               status "choose $ZIP_SID $ZIP_N"; exit 0 ;;
            *) fail "$ZIP_ERR" ;;
        esac
    fi
fi
# Basic sanity: iNES ROMs start with "NES" (then 0x1a).
case "$(dd if="$ROM" bs=3 count=1 2>/dev/null)" in
    NES) ;;
    *) fail "not an iNES ROM" ;;
esac

# Remember this URL for the phone's Settings -> Games menu (newest first, no
# duplicates, at most 8).
H=/snom/cfw/nes/history
{ echo "$URL"; grep -vxF "$URL" "$H" 2>/dev/null; } | head -n 8 > "$H.new" && mv "$H.new" "$H"


# Hold rcS's fast-update guard so killing the phone app doesn't reboot us. The
# engine itself kills lid+media_daemon (after arming hands-free audio while the
# daemon is still alive -- see snd/snd_hal.c).
. /snom/cfw/lib/saves.sh
saves_setup nes "$ROM"
touch /tmp/ssh_fast_update
status running

"$ENGINE" "$ROM" >> "$LOG" 2>&1 < /dev/null

echo "emulator exited with status $?" >> "$LOG"
status done
sync
rm -f "$ROM"

# Bring the stock phone app back without a reboot (docs/quit-without-reboot.md).
# Fall back to the old, always-working reboot if it isn't healthy within 60 s.
if /snom/cfw/lib/phone-restore.sh; then
    echo "phone app restored" >> "$LOG"
else
    echo "phone restore failed, rebooting" >> "$LOG"
    rm -f /tmp/ssh_fast_update
    sync
    reboot
fi
