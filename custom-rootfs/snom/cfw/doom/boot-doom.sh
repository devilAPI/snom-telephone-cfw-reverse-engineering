#!/bin/sh
# Boot Doom from a URL: download the WAD to RAM, take over the screen, run Doom,
# then reboot to restore the phone. Nothing is stored (the WAD is in /tmp and
# vanishes on the reboot). $1 = WAD URL.
ENGINE=/snom/cfw/doom/doom
LOG=/tmp/doom.log
URL="$1"

: > "$LOG"
[ -x "$ENGINE" ] || { echo "doom engine missing" >> "$LOG"; exit 1; }
[ -n "$URL" ]    || { echo "no URL" >> "$LOG"; exit 1; }

# Keep the WAD's real filename: Doom picks the game (Doom 1 vs Doom 2, Freedoom
# Phase 1 vs 2) from the IWAD *filename*. A generic name like doom.wad makes it
# assume Doom 1 and reject a Doom 2 IWAD ("d_introa not found").
NAME=$(basename "${URL%%\?*}")
case "$NAME" in
    *.wad|*.WAD) ;;
    *) NAME="freedoom2.wad" ;;   # best-effort default = Doom 2 mode
esac
WAD="/tmp/$NAME"

# Download FIRST, while the phone app is still up (so a bad URL leaves the phone
# usable and never blanks the screen).
rm -f "$WAD"
if ! curl -fkL --connect-timeout 15 --max-time 180 -o "$WAD" "$URL" >>"$LOG" 2>&1; then
    echo "download failed: $URL" >> "$LOG"
    rm -f "$WAD"
    exit 1
fi
# Basic sanity: a IWAD/PWAD starts with "IWAD" or "PWAD".
case "$(dd if="$WAD" bs=4 count=1 2>/dev/null)" in
    IWAD|PWAD) ;;
    *) echo "not a WAD file" >> "$LOG"; rm -f "$WAD"; exit 1 ;;
esac

touch /tmp/ssh_fast_update
kill -9 $(pidof lid) $(pidof media_daemon) 2>/dev/null
sleep 1

"$ENGINE" -iwad "$WAD" >> "$LOG" 2>&1 < /dev/null

rm -f "$WAD"
rm -f /tmp/ssh_fast_update
sync
reboot
