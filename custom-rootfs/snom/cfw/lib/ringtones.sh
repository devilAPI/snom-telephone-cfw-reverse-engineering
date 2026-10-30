# Custom ringtones helpers (busybox ash). Source after cfw.sh:  . /snom/cfw/lib/ringtones.sh
# See docs/ringtones.md for the why. Summary:
#  * files live in /snom/cfw-data/ringtones/NAME.wav
#  * /snom/cfw/ringtones is a symlink to that dir, so both httpds serve them statically
#    (lcsD375 fetches http://127.0.0.1:8081/ringtones/NAME.wav when the phone rings)
#  * a line plays it when user_customN=<that URL> and user_ringerN=Custom (stock settings,
#    written through the stock web server on 127.0.0.1:80, dummy.htm?settings=save)

RT_DIR=/snom/cfw-data/ringtones
RT_LINK=/snom/cfw/ringtones
RT_URL_BASE=http://127.0.0.1:8081/ringtones
RT_MAX_BYTES=1048576         # per file (lcsD375 limit, see docs/ringtones.md)
RT_MAX_TOTAL=8388608         # whole directory, keeps the shared jffs2 from filling up
RT_STOCK=http://127.0.0.1    # the stock web UI (lcsD375)

# rt_name_ok NAME: plain file name, [A-Za-z0-9._-], ends in .wav, no leading dot.
rt_name_ok() {
    case "$1" in
        ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
        *.wav) [ ${#1} -le 64 ] ;;
        *) return 1 ;;
    esac
}

# rt_dir: create the data dir and the serving symlink (self-healing). Prints the dir.
rt_dir() {
    _d=$(cfw_data_dir ringtones) || return 1
    if [ "$(readlink "$RT_LINK" 2>/dev/null)" != "$RT_DIR" ]; then
        rm -f "$RT_LINK" 2>/dev/null
        ln -s "$RT_DIR" "$RT_LINK" 2>/dev/null
    fi
    printf '%s\n' "$_d"
}

# rt_wav_info FILE: prints "FMT CHANNELS RATE BITS DATABYTES" from a RIFF/WAVE header
# (walks the chunks, so LIST/fact chunks before "data" are fine). Exit 1 if not a WAV.
rt_wav_info() {
    # busybox od here only knows the classic flags (-b = octal bytes; no -t/-N/-A).
    head -c 4096 "$1" 2>/dev/null | od -v -b | awk '
    { for (i = 2; i <= NF; i++) { o = $i; b[n++] = substr(o,1,1) * 64 + substr(o,2,1) * 8 + substr(o,3,1) } }
    function u16(o) { return b[o] + 256 * b[o+1] }
    function u32(o) { return b[o] + 256 * b[o+1] + 65536 * b[o+2] + 16777216 * b[o+3] }
    function id(o)  { return sprintf("%c%c%c%c", b[o], b[o+1], b[o+2], b[o+3]) }
    END {
        if (n < 44 || id(0) != "RIFF" || id(8) != "WAVE") exit 1
        o = 12; fmt = ""
        while (o + 8 <= n) {
            c = id(o); s = u32(o + 4)
            if (c == "fmt ") { fmt = u16(o+8); ch = u16(o+10); rate = u32(o+12); bits = u16(o+22) }
            if (c == "data") { if (fmt == "") exit 1; print fmt, ch, rate, bits, s; exit 0 }
            o += 8 + s + (s % 2)
        }
        exit 1
    }'
}

# rt_check FILE: prints "" and returns 0 if FILE is a format the phone plays, else prints
# the reason. Accepted (verified on the device, docs/ringtones.md): PCM 16-bit mono.
rt_check() {
    _i=$(rt_wav_info "$1") || { echo "not a WAV file (RIFF/WAVE header missing)"; return 1; }
    set -- $_i
    [ "$1" = 1 ] || { echo "WAV encoding $1 is not PCM (convert to 16-bit PCM)"; return 1; }
    [ "$2" = 1 ] || { echo "WAV has $2 channels, must be mono"; return 1; }
    [ "$4" = 16 ] || { echo "WAV has $4-bit samples, must be 16-bit"; return 1; }
    case "$3" in 8000|16000) ;; *) echo "sample rate $3 Hz not supported (use 8000 or 16000)"; return 1 ;; esac
    return 0
}

# rt_duration FILE: seconds (one decimal) from the header.
rt_duration() {
    _i=$(rt_wav_info "$1") || return 1
    set -- $_i
    awk -v r="$3" -v c="$2" -v b="$4" -v d="$5" 'BEGIN { if (r*c*b) printf "%.1f", d / (r * c * b / 8) }'
}

# rt_setting NAME: current value from /snom/snomconfig/config.xml ("" if at default).
# config.xml has CRLF line ends and only lists non-default settings.
rt_setting() {
    case "$1" in *[!a-z_0-9]*|'') return 1 ;; esac
    tr -d '\r' < /snom/snomconfig/config.xml 2>/dev/null | sed -n "s/^<${1%%[0-9]*} idx=\"${1##*[!0-9]}\"[^>]*>\\(.*\\)<\\/${1%%[0-9]*}>\$/\\1/p" | head -n 1
}

# rt_lines: identity numbers to offer (active ones, else 1).
rt_lines() {
    _l=$(tr -d '\r' < /snom/snomconfig/config.xml 2>/dev/null |
        sed -n 's/^<user_active idx="\([0-9]*\)"[^>]*>on<\/user_active>$/\1/p')
    [ -n "$_l" ] && printf '%s\n' $_l || echo 1
}

# rt_stock_ok: is the stock web server (lcsD375) answering? Fails fast when a game has
# SIGSTOPped/killed the phone app (Review Focus 2).
rt_stock_ok() {
    cfw_game_running && return 1
    pidof lcsD375 >/dev/null 2>&1 || return 1
    curl -s -m 3 -o /dev/null "$RT_STOCK/dummy.htm" 2>/dev/null
}

# rt_set_settings NAME=VALUE...: write stock settings through dummy.htm?settings=save.
# Values are passed with --data-urlencode (never through the shell or a hand-built URL).
# Prints an error and returns 1 on failure.
rt_set_settings() {
    rt_stock_ok || { echo "phone app is not running (game active?) - try again from the phone UI"; return 1; }
    _n=$#
    for _kv in settings=save "$@"; do set -- "$@" --data-urlencode "$_kv"; done
    shift "$_n"
    _code=$(curl -s -m 8 -o /dev/null -w '%{http_code}' -G "$@" "$RT_STOCK/dummy.htm")
    case "$_code" in
        200) return 0 ;;
        401) echo "the stock web UI asks for a password (http_user/http_pass set) - settings not changed"; return 1 ;;
        *) echo "stock web UI answered HTTP ${_code:-none} - settings not changed"; return 1 ;;
    esac
}

# rt_play_line N: the stock "Play Ringer" button of line N (plays that line's ringer).
rt_play_line() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    rt_stock_ok || { echo "phone app is not running (game active?)"; return 1; }
    _code=$(curl -s -m 8 -o /dev/null -w '%{http_code}' -X POST \
        --data "PLAY_RINGER:$1=Play" "$RT_STOCK/line_audio.htm?l=$1")
    [ "$_code" = 200 ] || { echo "stock web UI answered HTTP ${_code:-none}"; return 1; }
}
