#!/bin/sh
# Boot NES from a URL: download the ROM to RAM, take over the screen, run the
# emulator, then bring the phone app back (phone-restore.sh; reboot only if
# that fails). Nothing is stored. $1 = ROM URL.
ENGINE=/snom/cfw/nes/infones
ROM=/tmp/game.nes
LOG=/tmp/nes.log
URL="$1"

: > "$LOG"
[ -x "$ENGINE" ] || { echo "nes engine missing" >> "$LOG"; exit 1; }
[ -n "$URL" ]    || { echo "no URL" >> "$LOG"; exit 1; }

rm -f "$ROM"
if ! curl -fkL --connect-timeout 15 --max-time 180 -o "$ROM" "$URL" >>"$LOG" 2>&1; then
    echo "download failed: $URL" >> "$LOG"
    rm -f "$ROM"
    exit 1
fi
# Basic sanity: iNES ROMs start with "NES" (then 0x1a).
case "$(dd if="$ROM" bs=3 count=1 2>/dev/null)" in
    NES) ;;
    *) echo "not an iNES ROM" >> "$LOG"; rm -f "$ROM"; exit 1 ;;
esac

# Remember this URL for the phone's Settings -> Games menu (newest first, no
# duplicates, at most 8).
H=/snom/cfw/nes/history
{ echo "$1"; grep -vxF "$1" "$H" 2>/dev/null; } | head -n 8 > "$H.new" && mv "$H.new" "$H"


# Hold rcS's fast-update guard so killing the phone app doesn't reboot us. The
# engine itself kills lid+media_daemon (after arming hands-free audio while the
# daemon is still alive -- see snd/snd_hal.c).
. /snom/cfw/lib/saves.sh
saves_setup nes "$ROM"
touch /tmp/ssh_fast_update

"$ENGINE" "$ROM" >> "$LOG" 2>&1 < /dev/null

echo "emulator exited with status $?" >> "$LOG"
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
