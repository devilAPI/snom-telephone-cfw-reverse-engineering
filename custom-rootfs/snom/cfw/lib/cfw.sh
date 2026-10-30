# CFW shared shell library (busybox ash). Source with:  . /snom/cfw/lib/cfw.sh
# Rule: untrusted input is data. Nothing here ever eval's or word-splits it.

CFW_DATA=/snom/cfw-data

# cfw_urldecode: stdin -> stdout. '+' becomes space, %XX becomes the byte.
# Backslashes are doubled first so printf %b cannot interpret them; %00 is dropped.
cfw_urldecode() {
    _s=$(cat)
    _s=$(printf '%s' "$_s" | sed 's/\\/\\\\/g; s/+/ /g; s/%00//g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')
    printf '%b' "$_s"
}

# cfw_param NAME: value of NAME from the POST body (if POST) else QUERY_STRING.
# Read the POST body once, in the sourcing (main) shell. cfw_param is usually
# called as $(cfw_param x), i.e. in a subshell, so caching there would be lost
# and a second call would block on the already-consumed stdin.
# Only form-style bodies are read: raw uploads (image/png, audio/wav,
# application/octet-stream) are left on stdin for the CGI to stream to a file.
_cfw_read_body() {
    case "${CONTENT_TYPE:-}" in
        ''|application/x-www-form-urlencoded*|text/plain*) ;;
        *) return 0 ;;
    esac
    if [ "$REQUEST_METHOD" = POST ] && [ -z "${CFW_BODY_READ:-}" ]; then
        CFW_BODY_READ=1
        CFW_BODY=
        if [ "${CONTENT_LENGTH:-0}" -gt 0 ] 2>/dev/null; then
            CFW_BODY=$(head -c "$CONTENT_LENGTH")
        fi
    fi
}
_cfw_read_body

cfw_param() {
    case "$1" in *[!A-Za-z0-9_]*|'') return 1 ;; esac
    _cfw_read_body
    _v=
    if [ -n "${CFW_BODY:-}" ]; then
        _v=$(printf '%s' "$CFW_BODY" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1)
    fi
    if [ -z "$_v" ]; then
        _v=$(printf '%s' "$QUERY_STRING" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1)
    fi
    printf '%s' "$_v" | cfw_urldecode
}

cfw_html_escape() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
cfw_xml_escape()  { sed "s/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/\"/\&quot;/g; s/'/\&apos;/g"; }

# cfw_html_head TITLE: Content-type header + page chrome (CSS shared with the panel).
cfw_html_head() {
    _t=$(printf '%s' "${1:-CFW Settings}" | cfw_html_escape)
    printf 'Content-type: text/html\r\n\r\n'
    cat <<EOT
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$_t</title>
<style>
  body { font-family: sans-serif; background:#f0f0f0; color:#222; margin:0; padding:24px; }
  h1 { font-size:20px; margin:0 0 4px; }
  .sub { color:#777; font-size:12px; margin-bottom:20px; }
  .card { background:#fff; border:1px solid #ccc; border-radius:6px; padding:16px 18px; max-width:460px; margin:0 0 14px; }
  .card h2 { font-size:15px; margin:0 0 4px; }
  .card p { font-size:13px; color:#555; margin:0 0 12px; }
  input[type=url], input[type=text] { width:100%; box-sizing:border-box; padding:7px; margin:0 0 10px; border:1px solid #bbb; border-radius:4px; font-size:13px; }
  button { background:#2a6; color:#fff; border:0; border-radius:4px; padding:8px 18px; font-size:14px; cursor:pointer; }
  button:hover { filter:brightness(1.08); }
  code { background:#eee; padding:1px 4px; }
  .warn { color:#a40; font-size:12px; max-width:460px; }
  .ok { color:#176; } .err { color:#a40; } a { color:#2a6; }
</style>
</head>
<body>
EOT
}
cfw_html_foot() { printf '</body>\n</html>\n'; }

# cfw_phone_text TITLE TEXT: complete IPPhoneText response (headers included).
cfw_phone_text() {
    printf 'Content-type: text/xml\r\n\r\n'
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<IPPhoneText state="others_except_mb" dtmf="off">\n'
    printf '  <Title>%s</Title>\n  <Text>%s</Text>\n' \
        "$(printf '%s' "$1" | cfw_xml_escape)" "$(printf '%s' "$2" | cfw_xml_escape)"
    printf '  <SoftKeyItem>\n    <Name>CANCEL</Name>\n    <Url track="no">phone://mb_nop#go_back</Url>\n  </SoftKeyItem>\n</IPPhoneText>\n'
}

# cfw_data_dir FEATURE: create and print /snom/cfw-data/FEATURE. FEATURE is a plain name.
cfw_data_dir() {
    case "$1" in *[!A-Za-z0-9_.-]*|''|.|..) return 1 ;; esac
    mkdir -p "$CFW_DATA/$1" 2>/dev/null || return 1
    printf '%s\n' "$CFW_DATA/$1"
}

# cfw_rw / cfw_ro: remount / rw/ro only when needed. On the D375 / is jffs2 mounted rw
# already (see docs/cfw-dev.md), so these are normally no-ops. Only call cfw_ro if
# cfw_rw reported it changed something (CFW_REMOUNTED=1).
cfw_rw() {
    if ! touch /.cfw-rw-test 2>/dev/null; then
        mount -o remount,rw / && CFW_REMOUNTED=1
    else
        rm -f /.cfw-rw-test
    fi
}
cfw_ro() {
    [ "${CFW_REMOUNTED:-}" = 1 ] && mount -o remount,ro / && CFW_REMOUNTED=
    return 0
}

# cfw_game_running: exit 0 if a game/emulator engine from /snom/cfw/*/ is alive.
cfw_game_running() {
    for _p in /proc/[0-9]*; do
        _e=$(readlink "$_p/exe" 2>/dev/null) || continue
        case "$_e" in /snom/cfw/*/*) return 0 ;; esac
    done
    return 1
}
