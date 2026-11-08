#!/bin/sh
# CFW Navidrome player: plays a queue of tracks on the loudspeaker. See docs/navidrome.md.
#   player.sh start [IDX [OFFSET]]   play the queue ($ND_RUN/queue) from track IDX (0 = first)
#   player.sh stop | next | prev | pause | resume | toggle
#   player.sh vol N|up|down          volume 0..100 (saved in the config)
#   player.sh status                 key=value lines: state, idx, count, id, title, artist,
#                                    album, pos, duration, vol, error
# The queue has one track per line: id TAB title TAB artist TAB duration TAB album.
# Each track: busybox wget gets it from Navidrome as MP3 (format=mp3, maxBitRate), navplay
# decodes it and sends it to spkstream (the network speaker, docs/speaker.md) in its
# "player" channel, so a PC streaming to the speaker at the same time is mixed in. Pause
# remembers the position and starts again there with Navidrome's timeOffset.
. /snom/cfw/navidrome/nd-lib.sh
SPK=/snom/cfw/intercom/speaker.sh

lock() {
    _i=0
    while ! mkdir "$ND_RUN/lock" 2>/dev/null; do
        _i=$((_i + 1)); [ $_i -ge 20 ] && rm -rf "$ND_RUN/lock"; sleep 1
    done
}
unlock() { rmdir "$ND_RUN/lock" 2>/dev/null; }

alive() { [ -n "$1" ] && [ -d "/proc/$1" ]; }
loop_pid() { cat "$ND_RUN/loop.pid" 2>/dev/null; }
count() { [ -f "$ND_RUN/queue" ] && wc -l < "$ND_RUN/queue" | tr -d ' ' || echo 0; }
track() { sed -n "$(($1 + 1))p" "$ND_RUN/queue" 2>/dev/null; }   # track IDX: its queue line
field() { printf '%s' "$1" | cut -f"$2"; }
setstate() { printf '%s\n' "$*" > "$ND_RUN/state"; }

spk_token() { cat /tmp/speaker/token 2>/dev/null; }
spk_get() { wget -q -T 3 -O - "http://127.0.0.1:8091/$1?k=$(spk_token)${2:+&$2}" 2>/dev/null; }

# the speaker receiver must run; start it if needed (speaker.sh only when it is not
# running: it checks for games by walking /proc, which is slow)
spk_up() {
    _sp=$(cat /tmp/speaker/pid 2>/dev/null)
    [ -n "$_sp" ] && [ -d "/proc/$_sp" ] && [ -s /tmp/speaker/token ] && return 0
    _o=$("$SPK" start "$ND_VOL" 2>&1)
    case "$_o" in *running=1*) return 0 ;; esac
    printf '%s' "$_o" | sed -n 's/^error=//p' | head -n 1
    return 1
}

# pids of every running navplay, a stray one too. pidof, not a walk through /proc:
# that costs a fork per process and made next/start take 5 s on this CPU.
navplays() { pidof navplay 2>/dev/null; }

# stop the loop and its track; the speaker stops at once (no 2 s of buffered tail).
# loop.pid is cleared first: a loop that is still finishing sees it is no longer the
# current one and exits without touching the state (see owner in run_loop).
halt() {
    _p=$(loop_pid)
    rm -f "$ND_RUN/loop.pid"
    alive "$_p" && kill "$_p" 2>/dev/null
    for _n in $(navplays); do kill "$_n" 2>/dev/null; done
    _i=0; while { alive "$_p" || [ -n "$(navplays)" ]; } && [ $_i -lt 20 ]; do usleep 100000; _i=$((_i + 1)); done
    rm -f "$ND_RUN/play.pid"
    [ "${1:-}" = keep ] || spk_get stop ch=player >/dev/null
}

# seconds played of the current track (decoded + offset - what spkstream still holds)
position() { nd_status; echo "$NS_POS"; }

start_loop() {   # IDX OFFSET
    echo "$1" > "$ND_RUN/idx"; echo "${2:-0}" > "$ND_RUN/offset"
    rm -f "$ND_RUN/pos"
    setstate playing
    "$0" loop </dev/null >/dev/null 2>&1 &
    echo $! > "$ND_RUN/loop.pid"
}

# the loop: one track after another until the end of the queue. Only the loop whose pid
# is in loop.pid (the owner) changes the state; one that was replaced exits quietly.
run_loop() {
    me=$$; np=
    owner() { [ "$(loop_pid)" = "$me" ]; }
    trap '[ -n "$np" ] && kill "$np" 2>/dev/null; exit 0' TERM INT
    # start_loop writes our pid right after starting us; wait for it
    _i=0; while ! owner && [ $_i -lt 20 ]; do usleep 50000; _i=$((_i + 1)); done
    nd_load || { owner && setstate error "not set up"; exit 1; }
    fails=0
    while owner; do
        idx=$(cat "$ND_RUN/idx" 2>/dev/null); idx=${idx:-0}
        line=$(track "$idx")
        [ -n "$line" ] || { setstate stopped; nd_log "end of the queue"; exit 0; }
        id=$(field "$line" 1)
        nd_id "$id" || { echo $((idx + 1)) > "$ND_RUN/idx"; continue; }
        off=$(cat "$ND_RUN/offset" 2>/dev/null); off=${off:-0}
        e=$(spk_up) || { owner && setstate error "speaker: $e"; nd_log "speaker: $e"; exit 1; }
        setstate playing
        nd_log "play $idx: $(field "$line" 2) ($id) from ${off}s"
        nd_api scrobble "id=$id&submission=false" >/dev/null &
        q="id=$id&format=mp3&maxBitRate=$ND_BITRATE"
        [ "$off" -gt 0 ] && q="$q&timeOffset=$off"
        wget -q -T 20 -O - "$ND_URL/rest/stream.view?$(nd_auth)&$q" 2>>"$ND_RUN/log" |
            "$ND_DIR/navplay" -k "$(spk_token)" -v "$ND_VOL" -P "$ND_RUN/pos" 2>>"$ND_RUN/log" &
        np=$!; echo "$np" > "$ND_RUN/play.pid"
        wait "$np"; rc=$?; np=
        owner || exit 0
        rm -f "$ND_RUN/play.pid"
        case $rc in
            0)  fails=0
                nd_api scrobble "id=$id&submission=true" >/dev/null &
                echo $((idx + 1)) > "$ND_RUN/idx"; echo 0 > "$ND_RUN/offset"; rm -f "$ND_RUN/pos" ;;
            2)  # replaced by another sound in the player channel (the panel) or stopped
                nd_log "stopped by another sound"; setstate stopped; rm -f "$ND_RUN/loop.pid"; exit 0 ;;
            *)  fails=$((fails + 1)); nd_log "track $idx failed (rc $rc)"
                [ $fails -ge 3 ] && { setstate error "3 tracks in a row failed, see the log"; rm -f "$ND_RUN/loop.pid"; exit 1; }
                echo $((idx + 1)) > "$ND_RUN/idx"; echo 0 > "$ND_RUN/offset"; sleep 1 ;;
        esac
    done
}

status() {
    nd_status; nd_load
    echo "state=$NS_STATE"
    [ -n "$NS_ERROR" ] && echo "error=$NS_ERROR"
    printf 'idx=%s\ncount=%s\nid=%s\ntitle=%s\nartist=%s\nduration=%s\nalbum=%s\npos=%s\nvol=%s\n' \
        "$NS_IDX" "$NS_COUNT" "$NS_ID" "$NS_TITLE" "$NS_ARTIST" "$NS_DURATION" "$NS_ALBUM" "$NS_POS" "$ND_VOL"
}

set_vol() {
    nd_load
    case "$1" in
        up) v=$((ND_VOL + 10)) ;; down) v=$((ND_VOL - 10)) ;;
        [0-9]|[1-9][0-9]|100) v=$1 ;; *) echo "error=volume must be 0..100"; return 2 ;;
    esac
    [ $v -gt 100 ] && v=100; [ $v -lt 0 ] && v=0
    if grep -q '^VOL=' "$ND_CONF" 2>/dev/null; then sed -i "s/^VOL=.*/VOL=$v/" "$ND_CONF"
    else echo "VOL=$v" >> "$ND_CONF"; fi
    spk_get vol "v=$v&ch=player" >/dev/null
}

case "$1" in
    loop) run_loop ;;
    start)
        lock; nd_load || { unlock; echo "error=Navidrome is not set up (panel, tab Phone)"; exit 1; }
        i=${2:-0}; o=${3:-0}
        case "$i$o" in *[!0-9]*) unlock; echo "error=bad index"; exit 2 ;; esac
        [ "$(count)" -gt "$i" ] || { unlock; echo "error=nothing to play"; exit 1; }
        e=$(spk_up) || { unlock; setstate error "speaker: $e"; echo "error=speaker: $e"; exit 1; }
        halt keep; start_loop "$i" "$o"; unlock; status ;;
    stop) lock; halt; setstate stopped; unlock; status ;;
    next|prev)
        lock; nd_load
        i=$(cat "$ND_RUN/idx" 2>/dev/null); i=${i:-0}
        if [ "$1" = next ]; then i=$((i + 1))
        else
            # back to the start of the track if it has played more than 5 s
            [ "$(position)" -gt 5 ] || i=$((i - 1))
            [ $i -lt 0 ] && i=0
        fi
        if [ "$i" -ge "$(count)" ]; then halt; echo "$i" > "$ND_RUN/idx"; setstate stopped
        else halt keep; start_loop "$i" 0; fi
        unlock; status ;;
    pause)
        lock
        if [ "$(cat "$ND_RUN/state" 2>/dev/null)" = playing ] && alive "$(loop_pid)"; then
            p=$(position); halt; echo "$p" > "$ND_RUN/offset"; setstate paused
        fi
        unlock; status ;;
    resume)
        lock; nd_load
        if [ "$(cat "$ND_RUN/state" 2>/dev/null)" = paused ]; then
            i=$(cat "$ND_RUN/idx"); o=$(cat "$ND_RUN/offset" 2>/dev/null)
            e=$(spk_up) && { halt keep; start_loop "$i" "${o:-0}"; } || setstate error "speaker: $e"
        fi
        unlock; status ;;
    toggle)
        case "$(cat "$ND_RUN/state" 2>/dev/null)" in
            playing) alive "$(loop_pid)" && exec "$0" pause; exec "$0" start "$(cat "$ND_RUN/idx" 2>/dev/null || echo 0)" ;;
            paused) exec "$0" resume ;;
            *) [ "$(count)" -gt 0 ] && exec "$0" start "$(cat "$ND_RUN/idx" 2>/dev/null || echo 0)"; status ;;
        esac ;;
    vol) set_vol "$2"; status ;;
    status) status ;;
    *) echo "usage: $0 start [IDX [OFFSET]] | stop | next | prev | pause | resume | toggle | vol N|up|down | status" >&2; exit 2 ;;
esac
