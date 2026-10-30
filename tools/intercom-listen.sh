#!/usr/bin/env bash
# Listen to the snom D375 microphone on the PC (intercom / baby monitor, docs/intercom.md).
#
#   tools/intercom-listen.sh [options] [PHONE_IP]
#     -g N        gain 0..6 (digital shift, default 2 = x4) when starting
#     -r FILE     record to FILE (a .wav) instead of playing
#     -t SECS     stop after SECS seconds (with -r: a fixed-length recording)
#     -s          stop the intercom on the phone when done (default: leave it running)
#     -u U:P      panel credentials (once the panel login is on); or CFW_AUTH=user:pass
#
# Starts the intercom through the panel CGI if it is off, fetches the stream token,
# then pipes http://PHONE:8090/stream.wav?k=TOKEN into ffplay, aplay or paplay.
set -euo pipefail
IP=192.168.178.72 GAIN=2 REC= SECS= STOP=0 AUTH=${CFW_AUTH:-}
while getopts "g:r:t:su:h" o; do
    case $o in
        g) GAIN=$OPTARG ;; r) REC=$OPTARG ;; t) SECS=$OPTARG ;; s) STOP=1 ;; u) AUTH=$OPTARG ;;
        *) sed -n '2,13p' "$0"; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
[ $# -gt 0 ] && IP=$1

CURL=(curl -s -m 20)
[ -n "$AUTH" ] && CURL+=(-u "$AUTH")
cgi() { "${CURL[@]}" "http://$IP:8080/cgi-bin/intercom?a=$1&fmt=txt&g=$GAIN"; }
val() { sed -n "s/^$1=//p" <<<"$ST" | head -n 1; }

ST=$(cgi status)
if [ "$(val running)" != 1 ]; then
    echo "intercom is off, starting it ..." >&2
    ST=$(cgi start)
fi
if [ "$(val running)" != 1 ]; then
    echo "could not start the intercom: $(val error)${ST:+ }" >&2
    echo "$ST" >&2
    exit 1
fi
URL="http://$IP:$(val port)/stream.wav?k=$(val token)"
echo "streaming $URL  (the phone's mic is live; Ctrl-C to quit)" >&2

finish() { [ "$STOP" = 1 ] && { cgi stop >/dev/null || true; echo "intercom stopped" >&2; }; }
trap finish EXIT

STREAM=(curl -sN "$URL")
[ -n "$SECS" ] && STREAM=(curl -sN -m "$SECS" "$URL")
if [ -n "$REC" ]; then
    "${STREAM[@]}" > "$REC" || true    # curl -m exits 28 on the time limit
    echo "recorded $(stat -c %s "$REC") bytes to $REC" >&2
elif command -v ffplay >/dev/null; then
    "${STREAM[@]}" | ffplay -hide_banner -loglevel error -nodisp -fflags nobuffer -i - || true
elif command -v aplay >/dev/null; then
    "${STREAM[@]}" | aplay -q - || true
elif command -v paplay >/dev/null; then
    "${STREAM[@]}" | paplay || true
else
    echo "no player (ffplay/aplay/paplay) found; use -r FILE" >&2; exit 1
fi
