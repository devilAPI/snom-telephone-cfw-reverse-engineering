# saves.sh - persistent game saves (docs/saves.md). Source from a launcher.
#   saves_setup SYS ROMFILE   export CFW_SAVE_FILE=/snom/cfw-data/saves/SYS/<rom-sha1>.srm
#                             for the emulator engine (it loads/stores battery RAM there)
#   saves_dir_doom IWADNAME   print the Doom -savedir for this IWAD (created)
# A flash that is read-only/full only costs the saves: the problem is logged to
# $LOG and the engine logs the failed write too ("save: cannot write ...").
SAVES_ROOT=/snom/cfw-data/saves

saves_setup() {
    _sys=$1; _rom=$2
    _sha=$(sha1sum "$_rom" 2>/dev/null | cut -d' ' -f1)
    [ -n "$_sha" ] || { echo "warning: cannot hash $_rom, saves disabled" >> "${LOG:-/dev/null}"; return 1; }
    mkdir -p "$SAVES_ROOT/$_sys" 2>/dev/null ||
        echo "warning: cannot create $SAVES_ROOT/$_sys (flash read-only/full?), saves will fail" >> "${LOG:-/dev/null}"
    CFW_SAVE_FILE="$SAVES_ROOT/$_sys/$_sha.srm"
    export CFW_SAVE_FILE
    echo "save file: $CFW_SAVE_FILE" >> "${LOG:-/dev/null}"
}

saves_dir_doom() {
    _d="$SAVES_ROOT/doom/$1"
    mkdir -p "$_d" 2>/dev/null ||
        echo "warning: cannot create $_d (flash read-only/full?), Doom saves will fail" >> "${LOG:-/dev/null}"
    printf '%s' "$_d"
}
