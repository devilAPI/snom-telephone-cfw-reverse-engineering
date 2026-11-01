#!/bin/sh
# CFW intercom / baby monitor control (see docs/intercom.md).
#   intercom.sh start [GAIN] [MIC]   GAIN = digital gain shift 0..6 (default 2 = x4)
#                                    MIC  = speaker (default) | handset | headset | both
#                                    (running with another MIC: restarts with the new one)
#   intercom.sh stop
#   intercom.sh status         key=value lines: running, port, token, level, mic, error
# Used by cgi-bin/intercom (panel + phone menu) and tests/intercom.sh; also fine over ssh.
#
# start: insmod the stock amxr_user_hook.ko (gives /dev/amxruser), then run micstream,
#        which adds the amxr tap halaudio.apm0 -> amxruser.bind2, unmutes the idle-muted
#        ADC / mic preamp gains and serves http://<phone>:8090/stream.wav?k=<token>.
# stop:  TERM micstream (it disconnects the tap and re-mutes), rmmod the module if we loaded it.
# The phone UI keeps running the whole time; no takeover, no reboot.

D=/snom/cfw/intercom
RUN=/tmp/intercom
PIDF=$RUN/pid
TOKF=$RUN/token
MICF=$RUN/mic
LVL=$RUN/level
LOG=$RUN/log
KO=/lib/modules/2.6.27.47/BROADCOM/amxr_user_hook.ko
PORT=8090
CH=2

mkdir -p "$RUN"

running() {
    [ -f "$PIDF" ] || return 1
    _p=$(cat "$PIDF" 2>/dev/null)
    [ -n "$_p" ] && [ -d "/proc/$_p" ] || return 1
    case "$(readlink "/proc/$_p/exe" 2>/dev/null)" in */micstream) return 0 ;; esac
    return 1
}

# serialize start/stop (two CGI requests at once); stale lock older than 30 s is broken
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
        echo "level=$(cat "$LVL" 2>/dev/null)"
        echo "mic=$(cat "$MICF" 2>/dev/null)"
    else
        echo "running=0"
    fi
}

# Only unload the module if we loaded it and nobody else has a connection on its
# ports (other tools, e.g. audio tests, use amxruser.bind0/1 too).
module_unload() {
    [ -f "$RUN/ko_loaded" ] || return 0
    grep -q '^amxr_user_hook ' /proc/modules 2>/dev/null || { rm -f "$RUN/ko_loaded"; return 0; }
    grep -q -- '-> amxruser' /proc/amxr 2>/dev/null && return 0
    rm -f "$RUN/ko_loaded"
    rmmod amxr_user_hook 2>/dev/null && return 0
    sleep 1
    rmmod amxr_user_hook
}

do_stop() {
    if running; then
        _p=$(cat "$PIDF")
        kill "$_p" 2>/dev/null
        _i=0
        while [ -d "/proc/$_p" ] && [ $_i -lt 30 ]; do usleep 100000; _i=$((_i + 1)); done
        if [ -d "/proc/$_p" ]; then
            # stuck (should not happen): kill hard, then remove the tap + re-mute ourselves
            kill -9 "$_p" 2>/dev/null
            sleep 1
            "$D/micstream" -c "$CH" -x >>"$LOG" 2>&1
        fi
    fi
    rm -f "$PIDF" "$TOKF" "$LVL" "$MICF"
    module_unload || { echo "error=rmmod amxr_user_hook failed"; return 1; }
    return 0
}

do_start() {
    _g=${1:-2}
    case "$_g" in [0-6]) ;; *) echo "error=gain must be 0..6"; return 2 ;; esac
    _m=${2:-speaker}
    # APM channel + mic input per microphone, measured on the D375 (docs/intercom.md)
    case "$_m" in
        speaker) _sel="-c 1 -m 1" ;;
        handset) _sel="-c 0 -m 0" ;;
        headset) _sel="-c 0 -m 1" ;;
        both)    _sel="-c 2 -m 2" ;;
        *) echo "error=mic must be speaker, handset, headset or both"; return 2 ;;
    esac
    if running; then
        [ "$(cat "$MICF" 2>/dev/null)" = "$_m" ] && { status; return 0; }
        do_stop >/dev/null || { echo "error=could not stop the running intercom"; return 1; }
    fi
    if game_running; then
        echo "error=a game owns the audio hardware; quit it first"
        return 3
    fi
    if ! pidof media_daemon >/dev/null 2>&1; then
        echo "error=phone audio service (media_daemon) is not running"
        return 3
    fi
    [ -x "$D/micstream" ] || { echo "error=$D/micstream missing"; return 1; }
    [ -c /dev/amxruser ] || mknod /dev/amxruser c 236 0
    if ! grep -q '^amxr_user_hook ' /proc/modules 2>/dev/null; then
        insmod "$KO" >"$LOG" 2>&1 || { echo "error=insmod amxr_user_hook failed: $(tail -n 1 "$LOG")"; return 1; }
        touch "$RUN/ko_loaded"
    fi
    # busybox od here has no -A/-t; md5 of 32 random bytes, 96 bits kept
    _tok=$(head -c 32 /dev/urandom | md5sum | cut -c1-24)
    case "$_tok" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;; *) echo "error=could not make a token"; return 1 ;; esac
    printf '%s\n' "$_tok" > "$TOKF"
    chmod 600 "$TOKF"
    printf '%s\n' "$_m" > "$MICF"
    # $_sel is one of the fixed strings above: word splitting intended
    start-stop-daemon -S -b -m -p "$PIDF" -x "$D/micstream" -- \
        $_sel -g "$_g" -p "$PORT" -k "$_tok" -L "$LVL" -l "$LOG"
    _i=0
    while [ $_i -lt 15 ]; do
        usleep 100000
        _i=$((_i + 1))
        grep -q 'micstream: serving' "$LOG" 2>/dev/null && break
        running || break
    done
    if ! running || ! grep -q 'micstream: serving' "$LOG" 2>/dev/null; then
        _e=$(grep 'micstream:' "$LOG" 2>/dev/null | tail -n 1)
        do_stop >/dev/null 2>&1
        echo "error=micstream did not start: ${_e:-no output}"
        return 1
    fi
    status
}

case "$1" in
    start)  lock; do_start "$2" "$3"; r=$?; unlock; exit $r ;;
    stop)   lock; do_stop; r=$?; unlock; [ $r = 0 ] && status; exit $r ;;
    status) status ;;
    *) echo "usage: $0 start [GAIN 0..6] [speaker|handset|headset|both] | stop | status" >&2; exit 2 ;;
esac
