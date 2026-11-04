#!/usr/bin/env bash
# Use the snom D375 as a network speaker from a Linux PC (reverse intercom, docs/speaker.md).
#
#   tools/snom-speaker.sh [options] [PHONE_IP]
#     (no -f)     add a virtual sound output "snom D375" to PulseAudio / PipeWire and stream
#                 everything played on it to the phone's loudspeaker until Ctrl-C
#     -d          make "snom D375" the default output while this runs
#     -f FILE     play one file instead (anything ffmpeg reads: mp3, ogg, wav, a URL, ...)
#     -v VOL      volume 0..100 (default 30; the phone's speaker is loud)
#     -s          stop the speaker on the phone when done (default: leave it on)
#     -u U:P      panel login; or CFW_AUTH=user:pass; asked for when needed
#
# Starts the receiver through the panel CGI (port 8080, login), fetches its token, then
# sends 16 kHz mono S16LE to http://PHONE:8091/play?k=TOKEN.
# Needs: curl, and for the virtual output pactl plus parec (pulseaudio-utils, also works
# with pipewire-pulse) or pw-record. -f needs ffmpeg.
set -euo pipefail
IP=192.168.178.72 VOL=30 FILE="" DEF=0 STOP=0 AUTH=${CFW_AUTH:-}
SINK=snom_d375
while getopts "df:v:su:h" o; do
    case $o in
        d) DEF=1 ;; f) FILE=$OPTARG ;; v) VOL=$OPTARG ;; s) STOP=1 ;; u) AUTH=$OPTARG ;;
        *) sed -n '2,16p' "$0"; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
[ $# -gt 0 ] && IP=$1
case "$VOL" in [0-9]|[1-9][0-9]|100) ;; *) echo "volume must be 0..100" >&2; exit 2 ;; esac
need() { command -v "$1" >/dev/null || { echo "missing: $1 ($2)" >&2; exit 1; }; }
need curl curl

# --- panel CGI, with the login ---
cgi() {
    local a=(curl -s --connect-timeout 5 -m 20 -w '\n%{http_code}')
    [ -n "$AUTH" ] && a+=(-u "$AUTH")
    "${a[@]}" "http://$IP:8080/cgi-bin/speaker?a=$1&fmt=txt&v=$VOL"
}
call() {
    local out code
    # Only the status code counts: busybox httpd's 401 page is shorter than its
    # Content-Length, so curl exits 18 although the phone answered.
    out=$(cgi "$1") || true
    code=${out##*$'\n'}
    [ "$code" = 000 ] && { echo "phone $IP does not answer on port 8080" >&2; return 1; }
    if [ "$code" = 401 ] && [ -z "$AUTH" ]; then
        read -rsp "Panel password for root@$IP: " pw; echo >&2
        AUTH="root:$pw"
        out=$(cgi "$1") || true; code=${out##*$'\n'}
    fi
    [ "$code" = 200 ] || { echo "panel answered HTTP $code (wrong password?)" >&2; return 1; }
    ST=${out%$'\n'*}
}
val() { sed -n "s/^$1=//p" <<<"$ST" | head -n 1; }

call status || exit 1
[ "$(val running)" = 1 ] || { echo "speaker is off, starting it ..." >&2; call start || exit 1; }
[ "$(val running)" = 1 ] || { echo "could not start the speaker: $(val error)" >&2; exit 1; }
PLAY="http://$IP:$(val port)/play?k=$(val token)&vol=$VOL"

CLEAN=()
RP=
finish() {
    trap - EXIT INT TERM
    [ -n "$RP" ] && kill "$RP" 2>/dev/null
    local c; for c in "${CLEAN[@]}"; do eval "$c" >/dev/null 2>&1 || true; done
    [ "$STOP" = 1 ] && call stop && echo "speaker stopped on the phone" >&2
    exit 0
}
trap finish EXIT INT TERM

# --- one file ---
if [ -n "$FILE" ]; then
    need ffmpeg ffmpeg
    echo "playing $FILE on $IP ..." >&2
    # TCP paces ffmpeg: the phone takes 2 s ahead and then reads as fast as it plays.
    ffmpeg -nostdin -v error -i "$FILE" -f s16le -ac 1 -ar 16000 - |
        curl -s -T - -H 'Expect:' -H 'Content-Type: application/octet-stream' "$PLAY"
    exit 0
fi

# --- virtual output ---
need pactl "pulseaudio-utils or pipewire-pulse"
if pactl list short sinks | grep -q "[[:space:]]${SINK}[[:space:]]"; then
    echo "output $SINK exists already (another snom-speaker.sh?), using it" >&2
else
    MOD=$(pactl load-module module-null-sink sink_name=$SINK rate=16000 channels=1 channel_map=mono \
          'sink_properties=device.description="snom D375"')
    CLEAN+=("pactl unload-module $MOD")
fi
if [ "$DEF" = 1 ]; then
    OLD=$(pactl get-default-sink 2>/dev/null || true)
    pactl set-default-sink "$SINK"
    [ -n "$OLD" ] && CLEAN=("pactl set-default-sink $OLD" "${CLEAN[@]}")
fi
if command -v parec >/dev/null; then
    REC=(parec -d "$SINK.monitor" --format=s16le --rate=16000 --channels=1 --latency-msec=20 --raw)
elif command -v pw-record >/dev/null; then
    REC=(pw-record --target "$SINK" -P stream.capture.sink=true --rate 16000 --channels 1 --format s16 -)
else
    echo "missing: parec (pulseaudio-utils) or pw-record (pipewire)" >&2; exit 1
fi
echo "\"snom D375\" is a sound output now$([ "$DEF" = 1 ] && echo ' and the default'). Ctrl-C to quit." >&2

# The stream is a plain HTTP request without a length, over bash's /dev/tcp: curl would
# buffer 64 kB (2 s) of a pipe before sending. live=1 lets the phone drop audio when its
# clock is slower than the PC's, so the delay stays below 300 ms.
HOSTPATH=${PLAY#http://}; HP=${HOSTPATH%%/*}; PATHQ=/${HOSTPATH#*/}
while :; do
    if exec 3<>"/dev/tcp/${HP%:*}/${HP#*:}"; then
        printf 'POST %s&live=1 HTTP/1.0\r\nHost: %s\r\nContent-Type: application/octet-stream\r\n\r\n' "$PATHQ" "$HP" >&3
        # in the background + wait, so that Ctrl-C or a TERM runs finish at once
        "${REC[@]}" >&3 2>/dev/null &
        RP=$!
        wait "$RP" || true
        RP=
        exec 3>&-
    fi
    echo "connection to the phone lost, reconnecting in 2 s ..." >&2
    sleep 2
    call status || continue
    [ "$(val running)" = 1 ] || call start || continue
    PLAY="http://$IP:$(val port)/play?k=$(val token)&vol=$VOL"
    HOSTPATH=${PLAY#http://}; HP=${HOSTPATH%%/*}; PATHQ=/${HOSTPATH#*/}
done
