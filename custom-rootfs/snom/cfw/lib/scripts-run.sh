# CFW Scripts feature: shared runner (sourced by cgi-bin/phone-scripts and cgi-bin/scripts).
# busybox on the D375 has no `timeout` applet, so this is a watchdog loop.
SCRIPTS_TIMEOUT=20
scripts_name_ok() {  # NAME restricted to [A-Za-z0-9._-]+\.sh, no leading dot
    case "$1" in
        ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
        *.sh) [ "${#1}" -le 64 ] ;;
        *) return 1 ;;
    esac
}
scripts_dir() { mkdir -p /snom/cfw-data/scripts 2>/dev/null; echo /snom/cfw-data/scripts; }
# scripts_kill_tree PID: kill PID and all descendants (a bare `kill` would orphan `sleep 25`)
scripts_kill_tree() {
    local s c kids=""
    for s in /proc/[0-9]*/stat; do  # busybox ps has no -o; read ppid from /proc ("pid (comm) S ppid")
        c=${s#/proc/}; c=${c%/stat}
        [ "$(sed -n 's/^[0-9]* (.*) [A-Za-z] \([0-9]*\) .*/\1/p' "$s" 2>/dev/null)" = "$1" ] && kids="$kids $c"
    done
    kill -9 "$1" 2>/dev/null   # parent first, or the script moves on to its next command
    for c in $kids; do scripts_kill_tree "$c"; done
}
# scripts_run NAME: output (stdout+stderr, last 2000 bytes) -> stdout; sets SCRIPTS_RC
scripts_run() {
    d=$(scripts_dir); f="$d/$1"
    [ -f "$f" ] || { echo "Script not found: $1"; SCRIPTS_RC=127; return; }
    o=/tmp/scripts-out.$$
    sh "$f" >"$o" 2>&1 </dev/null &
    p=$!; i=0
    while kill -0 "$p" 2>/dev/null && [ "$i" -lt "$SCRIPTS_TIMEOUT" ]; do sleep 1; i=$((i+1)); done
    if kill -0 "$p" 2>/dev/null; then
        scripts_kill_tree "$p"; wait "$p" 2>/dev/null
        tail -c 2000 "$o"; echo
        echo "[killed: timeout after ${SCRIPTS_TIMEOUT}s]"; SCRIPTS_RC=124
    else
        wait "$p"; SCRIPTS_RC=$?
        tail -c 2000 "$o"
        [ -s "$o" ] || echo "(no output)"
        [ "$SCRIPTS_RC" -eq 0 ] || { echo; echo "[exit code $SCRIPTS_RC]"; }
    fi
    rm -f "$o"
}
