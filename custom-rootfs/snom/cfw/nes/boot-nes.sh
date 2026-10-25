#!/bin/sh
# Boot NES from a URL: download the ROM to RAM, take over the screen, run the
# emulator, then reboot to restore. Nothing is stored. $1 = ROM URL.
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

touch /tmp/ssh_fast_update
kill -9 $(pidof lid) $(pidof media_daemon) 2>/dev/null
sleep 1

"$ENGINE" "$ROM" >> "$LOG" 2>&1 < /dev/null

rm -f "$ROM"
rm -f /tmp/ssh_fast_update
sync
reboot
