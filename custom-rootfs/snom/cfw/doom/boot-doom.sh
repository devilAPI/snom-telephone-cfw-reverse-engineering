#!/bin/sh
# Boot Doom from a URL: download the WAD to RAM, take over the screen, run Doom,
# then bring the phone app back (phone-restore.sh; reboot only if that fails).
# Nothing is stored (the WAD is in /tmp and is deleted after the run). $1 = WAD URL. Progress/errors go to /tmp/doom.log
# (shown by /cgi-bin/doom-log on the CFW page).
ENGINE=/snom/cfw/doom/doom
LOG=/tmp/doom.log
URL="$1"
CURL="curl -fksSL --connect-timeout 15"

: > "$LOG"
log() { echo "$*" >> "$LOG"; }
fail() { log "ERROR: $*"; rm -f /tmp/doom-dl.wad; exit 1; }
urldecode() { printf '%b' "$(echo "$1" | sed 's/%\(..\)/\\x\1/g')"; }

[ -x "$ENGINE" ] || fail "doom engine missing"
[ -n "$URL" ]    || fail "no URL"
log "URL: $URL"

# archive.org: a /details/ link is the HTML viewer page; the file itself is
# served under /download/ with the same path.
case "$URL" in
    *archive.org/details/*) URL=$(echo "$URL" | sed 's|archive\.org/details/|archive.org/download/|')
                            log "archive.org details link -> $URL" ;;
esac

# archive.org item link without a file (.../download/<item>): pick the file
# from the item's metadata -- a known IWAD name, else any .wad, else a .zip.
ITEM=$(echo "${URL%%\?*}" | sed -n 's|^.*archive\.org/download/\([^/]*\)/*$|\1|p')
if [ -n "$ITEM" ]; then
    META=$($CURL --max-time 60 "https://archive.org/metadata/$ITEM/files" 2>>"$LOG") || fail "could not read archive.org item $ITEM"
    FILES=$(echo "$META" | grep -oE '"name": *"[^"]*\.([wW][aA][dD]|[zZ][iI][pP])"' | sed 's/^"name": *"//; s/"$//')
    PICK=$(echo "$FILES" | grep -iE '(^|/)(doom|doom1|doom2|plutonia|tnt|freedoom1|freedoom2|freedm|chex|hacx)\.wad$' | head -n 1)
    [ -n "$PICK" ] || PICK=$(echo "$FILES" | grep -iE '\.wad$' | head -n 1)
    [ -n "$PICK" ] || PICK=$(echo "$FILES" | grep -iE '\.zip$' | head -n 1)
    [ -n "$PICK" ] || fail "no .wad or .zip file in archive.org item $ITEM"
    URL="https://archive.org/download/$ITEM/$(echo "$PICK" | sed 's/ /%20/g')"
    log "archive.org item -> $URL"
fi

# The phone has no unzip, but archive.org extracts members of a .zip
# server-side (<zip>/<member>). Pick the IWAD from the zip's listing page,
# preferring a known IWAD name, else the first .wad.
case "$(echo "${URL%%\?*}" | tr A-Z a-z)" in
    *archive.org/download/*.zip|*archive.org/download/*.zip/)
        LIST=$($CURL --max-time 60 "${URL%/}/" 2>>"$LOG") || fail "could not list zip contents"
        MEMBERS=$(echo "$LIST" | grep -oiE 'href="[^"]*\.wad"' | sed 's/^href="//; s/"$//')
        PICK=""
        for m in $MEMBERS; do
            case "$(basename "$(urldecode "$m")" | tr A-Z a-z)" in
                doom.wad|doom1.wad|doom2.wad|plutonia.wad|tnt.wad|freedoom1.wad|freedoom2.wad|freedm.wad|chex.wad|hacx.wad)
                    PICK="$m"; break ;;
            esac
        done
        [ -n "$PICK" ] || PICK=$(echo "$MEMBERS" | head -n 1)
        [ -n "$PICK" ] || fail "no .wad file inside the zip"
        case "$PICK" in //*) PICK="https:$PICK" ;; /*) PICK="https://archive.org$PICK" ;; esac
        URL="$PICK"
        log "zip member -> $URL" ;;
    *.zip) fail "zip files are only supported from archive.org (no unzip on the phone); link the .wad directly" ;;
esac

# Download FIRST, while the phone app is still up (so a bad URL leaves the phone
# usable and never blanks the screen).
DL=/tmp/doom-dl.wad
rm -f "$DL"
log "downloading..."
$CURL --max-time 300 -o "$DL" "$URL" >>"$LOG" 2>&1 || fail "download failed (check the URL is a direct file link)"
log "downloaded $(wc -c < "$DL") bytes"

case "$(dd if="$DL" bs=4 count=1 2>/dev/null)" in
    IWAD) ;;
    PWAD) fail "this is a PWAD (add-on map pack); Doom needs an IWAD such as doom2.wad or freedoom2.wad" ;;
    "<!DO"|"<htm"|"<HTM") fail "got an HTML page, not a WAD (use the direct download link)" ;;
    *) fail "not a WAD file" ;;
esac

# Doom picks the game (Doom 1 vs Doom 2, Freedoom Phase 1 vs 2) from the IWAD
# *filename*: a wrong name makes it reject the WAD ("d_introa not found").
# Keep a known IWAD name (lowercased); otherwise detect from the map lumps.
NAME=$(basename "$(urldecode "${URL%%\?*}")" | tr A-Z a-z)
case "$NAME" in
    doom.wad|doom1.wad|doom2.wad|plutonia.wad|tnt.wad|freedoom1.wad|freedoom2.wad|freedm.wad|chex.wad|hacx.wad) ;;
    *) if grep -q MAP01 "$DL"; then NAME=doom2.wad
       elif grep -q E1M1 "$DL"; then NAME=doom.wad
       else fail "unrecognised IWAD (no MAP01 or E1M1 lump)"; fi
       log "unknown IWAD name, detected as $NAME" ;;
esac
WAD="/tmp/$NAME"
mv "$DL" "$WAD"

# Remember this URL for the phone's Settings -> Games menu (newest first, no
# duplicates, at most 8).
H=/snom/cfw/doom/history
{ echo "$1"; grep -vxF "$1" "$H" 2>/dev/null; } | head -n 8 > "$H.new" && mv "$H.new" "$H"

log "starting Doom with $WAD"

# Hold rcS's fast-update guard so killing the phone app doesn't reboot us. The
# engine itself kills lid+media_daemon (after arming hands-free audio while the
# daemon is still alive -- see snd/snd_hal.c).
. /snom/cfw/lib/saves.sh
SAVEDIR=$(saves_dir_doom "${NAME%.wad}")
touch /tmp/ssh_fast_update

"$ENGINE" -iwad "$WAD" -savedir "$SAVEDIR" >> "$LOG" 2>&1 < /dev/null
log "Doom exited with status $?"
sync

rm -f "$WAD"

# Bring the stock phone app back without a reboot (docs/quit-without-reboot.md).
# Fall back to the old, always-working reboot if it isn't healthy within 60 s.
if /snom/cfw/lib/phone-restore.sh; then
    log "phone app restored"
else
    log "phone restore failed, rebooting"
    # /tmp is lost on the reboot: keep this run's log on flash so the CFW page
    # can still show why Doom quit (e.g. an engine I_Error).
    tail -n 60 "$LOG" > /snom/cfw/doom/last.log 2>/dev/null
    rm -f /tmp/ssh_fast_update
    sync
    reboot
fi
