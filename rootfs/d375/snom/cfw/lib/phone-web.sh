# Talking to the phone app's own web server (sourced by CFW scripts). The D815 app
# requires a login, so it is read from the app's settings on every call: the
# password can be changed in the app. See docs/backport-guide.md.
PHONE_CONFIG=/snom/snomconfig/d815/config.xml
[ -f "$PHONE_CONFIG" ] && [ ! -f /snom/cfw-data/use-d375-app ] || PHONE_CONFIG=/snom/snomconfig/config.xml
PHONE_WEB=http://127.0.0.1

# phone_curl ARGS: curl with the app's login, if it has one.
phone_curl() {
    _u=$(tr -d '\r' < "$PHONE_CONFIG" | sed -n 's/^<http_user[^>]*>\([^<]*\)<.*/\1/p')
    _w=$(tr -d '\r' < "$PHONE_CONFIG" | sed -n 's/^<http_pass[^>]*>\([^<]*\)<.*/\1/p')
    if [ -n "$_u" ]; then
        curl --anyauth -u "$_u:$_w" "$@"
    else
        curl "$@"
    fi
}

# phone_admin: the app answers 403 on settings pages outside Administrator mode, and
# it leaves that mode by itself. Repeated logins do no harm.
phone_admin() {
    _a=$(tr -d '\r' < "$PHONE_CONFIG" | sed -n 's/^<admin_mode_password [^>]*>\([^<]*\)<.*/\1/p')
    [ -n "$_a" ] || return 0
    phone_curl -s -m 15 -o /dev/null --data-urlencode "admin_mode_login=$_a" \
        --data-urlencode Settings=Apply "$PHONE_WEB/advanced_network.htm" </dev/null
}

# phone_set NAME=VALUE...: save settings, to flash at once: settings=save alone
# only reaches flash much later, so a reboot would lose it. Values never pass
# through a hand-built URL.
phone_set() {
    phone_admin
    _n=$#
    for _kv in settings=save store_settings=save "$@"; do set -- "$@" --data-urlencode "$_kv"; done
    shift "$_n"
    [ "$(phone_curl -s -m 15 -o /dev/null -w '%{http_code}' -G "$@" "$PHONE_WEB/dummy.htm" </dev/null)" = 200 ]
}
