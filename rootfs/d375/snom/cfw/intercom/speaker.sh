#!/bin/sh
# CFW network speaker / reverse intercom control (see docs/speaker.md).
#   speaker.sh start [VOL]   VOL = 0..100, default volume for senders that don't set one (30)
#   speaker.sh stop
#   speaker.sh out speaker|handset   play on the loudspeaker or in the handset earpiece
#                            (saved in /snom/cfw-data/speaker/out, also for later starts)
#   speaker.sh status        key=value lines: running, port, token, playing, vol, out, error
# Used by cgi-bin/speaker (panel, phone menu, tools/device/snom-speaker.sh); also fine over ssh.
#
# start: load the stock amxr_user_hook.ko (shared with the intercom, amxr-mod.sh) and run
#        spkstream, which connects amxruser.bind0 -> halaudio.apm1 and plays what is sent
#        to http://<phone>:8091/play?k=<token> on the loudspeaker. The speaker output is
#        unmuted only while sound plays.
# stop:  TERM spkstream (it disconnects and mutes), unload the module if no one needs it.
# The phone UI keeps running the whole time.

D=/snom/cfw/intercom
RUN=/tmp/speaker
PIDF=$RUN/pid
TOKF=$RUN/token
LOG=$RUN/log
PORT=8091
OUTF=/snom/cfw-data/speaker/out

mkdir -p "$RUN"
. "$D/amxr-mod.sh"

running() {
    [ -f "$PIDF" ] || return 1
    _p=$(cat "$PIDF" 2>/dev/null)
    [ -n "$_p" ] && [ -d "/proc/$_p" ] || return 1
    # "(deleted)" after the binary was replaced by an update
    case "$(readlink "/proc/$_p/exe" 2>/dev/null)" in */spkstream|*/spkstream" (deleted)") return 0 ;; esac
    return 1
}

lock() {
    _i=0
    while ! mkdir "$RUN/lock" 2>/dev/null; do
        _i=$((_i + 1))
        if [ $_i -ge 30 ]; then rm -rf "$RUN/lock"; continue; fi
        sleep 1
    done
}
unlock() { rmdir "$RUN/lock" 2>/dev/null; }

game_running() {
    for _p in /proc/[0-9]*; do
        _e=$(readlink "$_p/exe" 2>/dev/null) || continue
        case "$_e" in /snom/cfw/doom/*|/snom/cfw/nes/*|/snom/cfw/gb/*|/snom/cfw/gba/*) return 0 ;; esac
    done
    return 1
}

status() {
    if running; then
        echo "running=1"
        echo "port=$PORT"
        echo "token=$(cat "$TOKF" 2>/dev/null)"
        # spkstream's own status, from the phone itself
        _s=$(wget -q -O - "http://127.0.0.1:$PORT/status?k=$(cat "$TOKF" 2>/dev/null)" 2>/dev/null)
        echo "playing=$(printf '%s' "$_s" | sed -n 's/.*"playing":\([0-9]*\).*/\1/p')"
        echo "vol=$(printf '%s' "$_s" | sed -n 's/.*"vol":\([0-9]*\).*/\1/p')"
        echo "out=$(printf '%s' "$_s" | sed -n 's/.*"out":"\([a-z]*\)".*/\1/p')"
    else
        echo "running=0"
    fi
}

do_stop() {
    if running; then
        _p=$(cat "$PIDF")
        kill "$_p" 2>/dev/null
        _i=0
        while [ -d "/proc/$_p" ] && [ $_i -lt 30 ]; do usleep 100000; _i=$((_i + 1)); done
        if [ -d "/proc/$_p" ]; then
            kill -9 "$_p" 2>/dev/null
            sleep 1
            "$D/spkstream" -x >>"$LOG" 2>&1
        fi
    fi
    rm -f "$PIDF" "$TOKF"
    amxr_mod_unload || { echo "error=rmmod amxr_user_hook failed"; return 1; }
    return 0
}

do_start() {
    _v=${1:-30}
    case "$_v" in [0-9]|[1-9][0-9]|100) ;; *) echo "error=volume must be 0..100"; return 2 ;; esac
    if running; then status; return 0; fi
    if game_running; then echo "error=a game owns the audio hardware; quit it first"; return 3; fi
    pidof media_daemon >/dev/null 2>&1 || { echo "error=phone audio service (media_daemon) is not running"; return 3; }
    [ -x "$D/spkstream" ] || { echo "error=$D/spkstream missing"; return 1; }
    : > "$LOG"
    amxr_mod_load "$LOG" || { echo "error=insmod amxr_user_hook failed: $(tail -n 1 "$LOG")"; return 1; }
    _tok=$(head -c 32 /dev/urandom | md5sum | cut -c1-24)
    case "$_tok" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;; *) echo "error=could not make a token"; return 1 ;; esac
    printf '%s\n' "$_tok" > "$TOKF"
    chmod 600 "$TOKF"
    _o=$(cat "$OUTF" 2>/dev/null); case "$_o" in speaker|handset) ;; *) _o=speaker ;; esac
    start-stop-daemon -S -b -m -p "$PIDF" -x "$D/spkstream" -- -p "$PORT" -k "$_tok" -v "$_v" -o "$_o" -l "$LOG"
    _i=0
    while [ $_i -lt 15 ]; do
        usleep 100000
        _i=$((_i + 1))
        grep -q 'spkstream: serving' "$LOG" 2>/dev/null && break
        running || break
    done
    if ! running || ! grep -q 'spkstream: serving' "$LOG" 2>/dev/null; then
        _e=$(grep 'spkstream:' "$LOG" 2>/dev/null | tail -n 1)
        do_stop >/dev/null 2>&1
        echo "error=spkstream did not start: ${_e:-no output}"
        return 1
    fi
    status
}

case "$1" in
    start)  lock; do_start "$2"; r=$?; unlock; exit $r ;;
    stop)   lock; do_stop; r=$?; unlock; [ $r = 0 ] && status; exit $r ;;
    out)
        case "$2" in speaker|handset) ;; *) echo "error=output must be speaker or handset"; exit 2 ;; esac
        mkdir -p "${OUTF%/*}" && echo "$2" > "$OUTF"
        running && wget -q -O /dev/null "http://127.0.0.1:$PORT/out?k=$(cat "$TOKF")&o=$2"
        status ;;
    status) status ;;
    *) echo "usage: $0 start [VOL 0..100] | stop | out speaker|handset | status" >&2; exit 2 ;;
esac
