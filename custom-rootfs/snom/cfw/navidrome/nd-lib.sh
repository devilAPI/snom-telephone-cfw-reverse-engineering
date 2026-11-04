# CFW Navidrome player: shared helpers (sourced). See docs/navidrome.md.
# Config: /snom/cfw-data/navidrome/conf, key=value lines written by cgi-bin/navidrome:
#   URL=http://server:4533   (http only: busybox wget has no TLS)
#   USER=name  SALT=hex  TOKEN=md5(password+salt)   (the password itself is not stored)
#   BITRATE=96  VOL=30
# Runtime state: /tmp/navidrome/ (queue, idx, state, pos, offset, pids, log).
#
# Speed: the phone's CPU is busy (the phone app takes ~35 %, load ~6) and a fork costs
# around 100 ms. The first version needed 5 to 10 s per menu, nearly all of it in forks
# (5 per cfw_param, 2 per escaped menu item, sed per config key). So: one awk call parses
# the whole request, one renders a whole menu, and config and status are read with the
# shell's own read.

ND_CONF=/snom/cfw-data/navidrome/conf
ND_RUN=/tmp/navidrome
ND_DIR=/snom/cfw/navidrome
mkdir -p "$ND_RUN"

# nd_get KEY: value from the config (read with sed, never sourced)
nd_get() { sed -n "s/^$1=//p" "$ND_CONF" 2>/dev/null | head -n 1; }

# nd_load: the config into ND_* (the shell's read, no fork; never sourced)
nd_load() {
    ND_URL=; ND_USER=; ND_SALT=; ND_TOKEN=; ND_BITRATE=; ND_VOL=; ND_AUTH=
    if [ -f "$ND_CONF" ]; then
        while IFS='=' read -r _k _v; do
            case "$_k" in
                URL) ND_URL=$_v ;; USER) ND_USER=$_v ;; SALT) ND_SALT=$_v ;; TOKEN) ND_TOKEN=$_v ;;
                BITRATE) ND_BITRATE=$_v ;; VOL) ND_VOL=$_v ;;
            esac
        done < "$ND_CONF"
    fi
    case "$ND_BITRATE" in 32|48|64|96|128|160|192) ;; *) ND_BITRATE=96 ;; esac
    case "$ND_VOL" in [0-9]|[1-9][0-9]|100) ;; *) ND_VOL=30 ;; esac
    [ -n "$ND_URL" ] && [ -n "$ND_USER" ] && [ -n "$ND_TOKEN" ]
}

# nd_urlenc: stdin -> percent-encoded (everything but A-Za-z0-9 -_.~)
# busybox od here has no -A/-t: -b gives octal bytes after an offset column.
nd_urlenc() {
    od -b -v | awk '{
        for (i = 2; i <= NF; i++) {
            o = $i; v = 0
            for (k = 1; k <= length(o); k++) v = v * 8 + substr(o, k, 1)
            if ((v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v == 45 || v == 46 || v == 95 || v == 126)
                printf "%c", v
            else printf "%%%02X", v
        }
    }'
}

# nd_auth: the query string part that logs in (computed once per process)
nd_auth() {
    if [ -z "$ND_AUTH" ]; then
        case "$ND_USER" in
            *[!A-Za-z0-9._~-]*) _u=$(printf '%s' "$ND_USER" | nd_urlenc) ;;
            *) _u=$ND_USER ;;
        esac
        ND_AUTH="u=$_u&t=$ND_TOKEN&s=$ND_SALT&v=1.16.1&c=snomcfw"
    fi
    printf '%s' "$ND_AUTH"
}

# nd_api METHOD [QUERY]: the raw XML answer on stdout; 1 if the server can't be reached
nd_api() {
    [ -n "$ND_AUTH" ] || nd_auth >/dev/null
    wget -q -T 15 -O - "$ND_URL/rest/$1.view?$ND_AUTH${2:+&$2}" 2>/dev/null
}

# nd_params KEYS: stdin is "body&query"; prints "key TAB value" for each key in KEYS
# (space separated), URL-decoded, the first one wins, control characters become spaces.
# Read the output with "while IFS=TAB read -r k v; do case $k ...": nothing is evaluated.
nd_params() {
    awk -v keys=" $* " 'BEGIN { RS = "&"; for (i = 1; i < 256; i++) ch[sprintf("%02x", i)] = sprintf("%c", i) }
    { sub(/\n$/, ""); p = index($0, "="); if (!p) next; k = substr($0, 1, p - 1)
      if (!index(keys, " " k " ") || (k in seen)) next; seen[k] = 1
      v = substr($0, p + 1); gsub(/\+/, " ", v); out = ""
      while (match(v, /%[0-9A-Fa-f][0-9A-Fa-f]/)) { out = out substr(v, 1, RSTART - 1) ch[tolower(substr(v, RSTART + 1, 2))]; v = substr(v, RSTART + 3) }
      out = out v; gsub(/[\001-\037]/, " ", out); print k "\t" out }'
}

# nd_menu TITLE < items: a whole IPPhoneMenu from "name TAB url" lines, escaped, with
# the CANCEL softkey. One awk call for the whole menu.
nd_menu() {
    awk -F '\t' -v title="$1" '
    function x(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s)
                    gsub(/"/, "\\&quot;", s); gsub(/\047/, "\\&apos;", s); return s }
    BEGIN { printf "Content-type: text/xml\r\n\r\n<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            printf "<IPPhoneMenu state=\"others_except_mb\" dtmf=\"off\">\n  <Title>%s</Title>\n", x(title) }
    NF >= 2 { printf "  <MenuItem name=\"%s\">\n    <Url>%s</Url>\n  </MenuItem>\n", x($1), x($2) }
    END { printf "  <SoftKeyItem>\n    <Name>CANCEL</Name>\n    <Url track=\"no\">phone://mb_nop#go_back</Url>\n  </SoftKeyItem>\n</IPPhoneMenu>\n" }'
}

# nd_status: the player state into NS_* (state idx count id title artist duration album
# pos error), with one awk call for the queue and one wget for the speaker's buffer.
nd_status() {
    NS_STATE=stopped; NS_IDX=0; NS_POS=0; NS_ERROR=
    [ -f "$ND_RUN/state" ] && read -r NS_STATE < "$ND_RUN/state"
    case "$NS_STATE" in error\ *) NS_ERROR=${NS_STATE#error }; NS_STATE=error ;; esac
    [ -f "$ND_RUN/idx" ] && read -r NS_IDX < "$ND_RUN/idx"
    case "$NS_IDX" in ''|*[!0-9]*) NS_IDX=0 ;; esac
    if [ "$NS_STATE" = playing ]; then
        read -r _lp < "$ND_RUN/loop.pid" 2>/dev/null || _lp=
        [ -n "$_lp" ] && [ -d "/proc/$_lp" ] || NS_STATE=stopped
    fi
    NS_COUNT=0; NS_ID=; NS_TITLE=; NS_ARTIST=; NS_DURATION=0; NS_ALBUM=
    if [ -f "$ND_RUN/queue" ]; then
        IFS='	' read -r NS_COUNT NS_ID NS_TITLE NS_ARTIST NS_DURATION NS_ALBUM <<EOT
$(awk -F '\t' -v n=$((NS_IDX + 1)) 'NR == n { l = $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 } END { print NR "\t" l }' "$ND_RUN/queue")
EOT
    fi
    case "$NS_DURATION" in ''|*[!0-9]*) NS_DURATION=0 ;; esac
    case "$NS_STATE" in
        playing)
            _d=0; _o=0; [ -f "$ND_RUN/pos" ] && read -r _d < "$ND_RUN/pos"; [ -f "$ND_RUN/offset" ] && read -r _o < "$ND_RUN/offset"
            _t=; [ -f /tmp/speaker/token ] && read -r _t < /tmp/speaker/token
            _s=$(wget -q -T 3 -O - "http://127.0.0.1:8091/status?k=$_t" 2>/dev/null)
            _b=${_s#*\"player\":\{\"playing\":?,\"buffered_ms\":}; _b=${_b%%,*}
            case "$_b" in ''|*[!0-9]*) _b=0 ;; esac
            NS_POS=$(( ${_d:-0} + ${_o:-0} - _b / 1000 )); [ $NS_POS -lt 0 ] && NS_POS=0 ;;
        paused) [ -f "$ND_RUN/offset" ] && read -r NS_POS < "$ND_RUN/offset" ;;
    esac
    case "$NS_POS" in ''|*[!0-9]*) NS_POS=0 ;; esac
}

# nd_err XML: the error message of a failed answer, empty if status="ok"
nd_err() {
    case "$1" in
        *'status="ok"'*) ;;
        '') echo "the server does not answer" ;;
        *) printf '%s' "$1" | sed -n 's/.*<error [^>]*message="\([^"]*\)".*/\1/p' | head -n 1 | grep . || echo "unexpected answer" ;;
    esac
}

# nd_list TAG FIELD... : one line per <TAG ...> element, the FIELD attributes
# tab-separated and XML-unescaped. Reads XML on stdin.
nd_list() {
    _tag=$1; shift
    awk -v tag="$_tag" -v fields="$*" '
    BEGIN { RS = "<"; n = split(fields, F, " ") }
    function un(v) {
        gsub(/&quot;/, "\"", v); gsub(/&apos;/, "\047", v); gsub(/&#39;/, "\047", v)
        gsub(/&lt;/, "<", v); gsub(/&gt;/, ">", v); gsub(/&amp;/, "\\&", v)
        gsub(/[\t\r\n]/, " ", v)
        return v
    }
    index($0, tag " ") == 1 || index($0, tag "/") == 1 || index($0, tag ">") == 1 {
        line = ""
        for (i = 1; i <= n; i++) {
            v = ""
            if (match($0, " " F[i] "=\"[^\"]*\"")) v = substr($0, RSTART + length(F[i]) + 3, RLENGTH - length(F[i]) - 4)
            # (busybox awk reads "line (" as a call of a function "line")
            sep = i > 1 ? "\t" : ""
            line = line sep un(v)
        }
        print line
    }'
}

# nd_id ID: 0 if ID looks like a Subsonic id (letters, digits, - _ . :)
nd_id() { case "$1" in ''|*[!A-Za-z0-9_.:-]*) return 1 ;; esac; [ ${#1} -le 64 ]; }

nd_log() { echo "$(date '+%H:%M:%S') $*" >> "$ND_RUN/log"; }
