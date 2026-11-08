#!/bin/sh
# Boot Doom from a URL: download the WAD to RAM, run Doom on the phone screen, then
# bring the phone app back. Nothing is stored but the URL history and the saves.
# $1 = WAD URL (an archive.org item, details page or zip works too), or
# --pick SID IDX for a multi-WAD zip. Status and log: see lib/game.sh.
SYS=doom URL=$1 ROM=/tmp/doom-dl.wad
ENGINE=/snom/cfw/doom/doom
. /snom/cfw/lib/game.sh
CURL="curl -fksSL --connect-timeout 15 --max-time 60"
# Doom picks the game (Doom 1 or 2, Freedoom Phase 1 or 2) from the IWAD file name.
IWADS='doom|doom1|doom2|plutonia|tnt|freedoom1|freedoom2|freedm|chex|hacx'
is_iwad() { echo "$1" | grep -qiE "(^|/)($IWADS)\.wad$"; }
urldecode() { printf '%b' "$(echo "$1" | sed 's/%\(..\)/\\x\1/g')"; }

game_start "$ENGINE"
[ -n "$URL" ] || fail "no URL"
ORIGURL=$URL PICKED=
if [ "$URL" = --pick ]; then
    game_pick "$2" "$3"
    ORIGURL=$URL
else
    # archive.org: a /details/ link is the viewer page; the file is under /download/.
    URL=$(echo "$URL" | sed 's|archive\.org/details/|archive.org/download/|')
    # An item without a file (.../download/<item>): pick from the item's metadata,
    # a known IWAD name, else any .wad, else a .zip.
    ITEM=$(echo "${URL%%\?*}" | sed -n 's|^.*archive\.org/download/\([^/]*\)/*$|\1|p')
    if [ -n "$ITEM" ]; then
        META=$($CURL "https://archive.org/metadata/$ITEM/files" 2>>"$LOG") || fail "could not read archive.org item $ITEM"
        FILES=$(echo "$META" | grep -oE '"name": *"[^"]*\.([wW][aA][dD]|[zZ][iI][pP])"' | sed 's/^"name": *"//; s/"$//')
        PICK=$(echo "$FILES" | grep -iE "(^|/)($IWADS)\.wad$" | head -n 1)
        [ -n "$PICK" ] || PICK=$(echo "$FILES" | grep -iE '\.wad$' | head -n 1)
        [ -n "$PICK" ] || PICK=$(echo "$FILES" | grep -iE '\.zip$' | head -n 1)
        [ -n "$PICK" ] || fail "no .wad or .zip file in archive.org item $ITEM"
        URL="https://archive.org/download/$ITEM/$(echo "$PICK" | sed 's/ /%20/g')"
    fi
    # archive.org unpacks zip members server-side (<zip>/<member>), which saves RAM;
    # any other zip is unpacked on the phone. Prefer a known IWAD, else the first .wad.
    case "$(echo "${URL%%\?*}" | tr A-Z a-z)" in
        *archive.org/download/*.zip|*archive.org/download/*.zip/)
            LIST=$($CURL "${URL%/}/" 2>>"$LOG") || fail "could not list zip contents"
            MEMBERS=$(echo "$LIST" | grep -oiE 'href="[^"]*\.wad"' | sed 's/^href="//; s/"$//')
            PICK=
            for m in $MEMBERS; do is_iwad "$(urldecode "$m")" && { PICK=$m; break; }; done
            [ -n "$PICK" ] || PICK=$(echo "$MEMBERS" | head -n 1)
            [ -n "$PICK" ] || fail "no .wad file inside the zip"
            case "$PICK" in //*) PICK="https:$PICK" ;; /*) PICK="https://archive.org$PICK" ;; esac
            URL=$PICK ;;
    esac
    [ "$URL" = "$ORIGURL" ] || log "resolved to $URL"
    # Download first, while the phone app is still up: a bad URL never blanks the screen.
    ZIP_FROM=$ORIGURL game_fetch "$URL" 67108864
fi

case "$(dd if="$ROM" bs=4 count=1 2>/dev/null)" in
    IWAD) ;;
    PWAD) fail "this is a PWAD (add-on map pack); Doom needs an IWAD such as doom2.wad or freedoom2.wad" ;;
    "<!DO"|"<htm"|"<HTM") fail "got an HTML page, not a WAD (use the direct download link)" ;;
    *) fail "not a WAD file" ;;
esac
# Keep a known IWAD name (lowercased); otherwise detect the game from the map lumps.
NAME=$(basename "${PICKED:-$(urldecode "${URL%%\?*}")}" | tr A-Z a-z)
if ! is_iwad "$NAME"; then
    if grep -q MAP01 "$ROM"; then NAME=doom2.wad
    elif grep -q E1M1 "$ROM"; then NAME=doom.wad
    else fail "unrecognised IWAD (no MAP01 or E1M1 lump)"; fi
    log "unknown IWAD name, detected as $NAME"
fi
ROM=/tmp/$NAME
mv /tmp/doom-dl.wad "$ROM"

game_history /snom/cfw/doom "$ORIGURL"
SAVEDIR=$(saves_dir_doom "${NAME%.wad}")
CFW_GAME_ID=${NAME%.wad}; export CFW_GAME_ID   # keymap id (docs/keymap.md)
log "starting Doom with $ROM"
game_run "$ENGINE" -iwad "$ROM" -savedir "$SAVEDIR"
