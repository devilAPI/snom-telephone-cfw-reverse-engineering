# Shared steps of the game launchers (lib/retro-boot.sh, doom/boot-doom.sh), busybox ash.
# Set SYS (doom|nes|gb|gba) and ROM (the download in /tmp) before sourcing.
# Progress for the CGIs goes to /tmp/$SYS.status, one word + message:
#   downloading | error <message> | choose <sid> <n> | running | done
# and the full log to /tmp/$SYS.log.

# We may be started from a CGI: keep cfw.sh from reading a POST body.
unset REQUEST_METHOD CONTENT_LENGTH QUERY_STRING
. /snom/cfw/lib/cfw.sh
. /snom/cfw/lib/zip.sh
. /snom/cfw/lib/saves.sh
LOG=/tmp/$SYS.log
STATUS=/tmp/$SYS.status
: > "$LOG"

log() { echo "$*" >> "$LOG"; }
status() { printf '%s\n' "$*" > "$STATUS"; }
fail() { log "error: $*"; status "error $*"; rm -f "$ROM"; exit 1; }

# game_start ENGINE: first checks of every launch.
game_start() {
    status downloading
    [ -x "$1" ] || fail "engine $1 is missing"
    if cfw_game_running; then fail "another game is running"; fi
    rm -f "$ROM"
}

# game_pick SID IDX: second step of a multi-file zip (lib/zip.sh, docs/zip.md): entry
# IDX of the stored list becomes $ROM. Sets URL to the zip's URL and PICKED to the name.
game_pick() {
    zip_pick "$SYS" "$1" "$2" || fail "$ZIP_ERR"
    URL=$ZIP_URL PICKED=$(basename "$ZIP_ROM")
    mv "$ZIP_ROM" "$ROM" || fail "cannot move the chosen file"
    zip_clear "$SYS"
    log "chosen entry $2 of the zip from $URL"
}

# game_fetch URL MAXBYTES [curl args]: download URL to $ROM. A zip holding one game
# becomes $ROM; with several, the status becomes "choose" and the launcher exits
# (game_pick starts the chosen one later).
game_fetch() {
    _url=$1 _max=$2; shift 2
    zip_clear "$SYS"
    log "downloading $_url"
    # -f: HTTP errors fail; --max-filesize keeps an endless/huge download out of /tmp.
    curl -fkL --connect-timeout 15 --max-time 300 --max-filesize "$_max" "$@" \
            -o "$ROM" -- "$_url" >>"$LOG" 2>&1 ||
        fail "download failed (bad URL, unreachable, or larger than $((_max / 1048576)) MiB)"
    log "downloaded $(wc -c < "$ROM") bytes"
    zip_is_zip "$ROM" || return 0
    log "zip archive, unpacking"
    zip_extract "$SYS" "$ROM" "$(zip_ext "$SYS")" "${ZIP_FROM:-$_url}"
    case $? in
        0) PICKED=$(basename "$ZIP_ROM")
           mv "$ZIP_ROM" "$ROM" && zip_clear "$SYS" || fail "cannot move the unpacked file" ;;
        2) log "zip holds $ZIP_N files, waiting for a choice:"; cat "/tmp/zip-$SYS/list" >> "$LOG"
           status "choose $ZIP_SID $ZIP_N"; exit 0 ;;
        *) fail "$ZIP_ERR" ;;
    esac
}

# game_history DIR URL: remember URL for the phone's Settings -> Games menu (newest
# first, no duplicates, at most 8). A read-only or full flash only loses the history.
game_history() {
    _h=$1/history
    { printf '%s\n' "$2"; grep -vxF -- "$2" "$_h" 2>/dev/null; } | head -n 8 > "$_h.new" &&
        mv "$_h.new" "$_h" || { rm -f "$_h.new"; log "warning: cannot write $_h"; }
}

# game_run ENGINE ARGS...: take over the screen, run the engine, then bring the phone
# app back (docs/quit-without-reboot.md), rebooting only if that fails. The engine
# kills lid + media_daemon itself after arming the loudspeaker (src/audio/snd/snd_hal.c).
# A libretro engine exits 2 when it refuses the ROM before the takeover.
game_run() {
    touch /tmp/ssh_fast_update   # rcS's fast-update guard: killing the phone app must not reboot
    status running
    "$@" >> "$LOG" 2>&1 < /dev/null
    _rc=$?
    rm -f "$ROM"
    log "engine exit $_rc"
    sync
    if [ "$_rc" = 2 ] && [ "$SYS" != doom ] && [ "$SYS" != nes ]; then
        rm -f /tmp/ssh_fast_update
        status "error the emulator could not load this ROM (see $LOG)"
        exit 1
    fi
    status done
    if /snom/cfw/lib/phone-restore.sh; then
        log "phone app restored"
        return 0
    fi
    log "phone restore failed, rebooting"
    # /tmp is lost on the reboot: the doom-log CGI shows this copy.
    [ "$SYS" = doom ] && tail -n 60 "$LOG" > /snom/cfw/doom/last.log 2>/dev/null
    rm -f /tmp/ssh_fast_update
    sync
    reboot
}
