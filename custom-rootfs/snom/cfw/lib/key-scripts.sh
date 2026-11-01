# CFW scripts on the phone's programmable keys. Source after phone-web.sh and
# scripts-run.sh. A key runs a script through the phone's own "url" key function,
# so it stays an ordinary key that can be seen and changed in the phone's settings.
# Keys are numbered 1 to 12, as printed on the phone; the settings count from 0.
KS_KEYS="1 2 3 4 5 6 7 8 9 10 11 12"
KS_URL=http://127.0.0.1:8081/cgi-bin/key-script?run=

# ks_load: fill KS_MAP with "KEY=NAME.sh" lines for the keys that run a script.
# settings.xml, because settings.htm takes the phone about 20 s to go through.
ks_load() {
    phone_admin
    KS_MAP=$(phone_curl -s -m 15 "$PHONE_WEB/settings.xml" </dev/null | tr -d '\r' |
        sed -n "s|^<fkey idx=\"\([0-9]*\)\"[^>]*>url $KS_URL\([^<]*\)</fkey>.*|\1 \2|p" |
        while read -r _i _n; do echo "$((_i + 1))=$_n"; done)
}

# ks_get KEY: the script on KEY, if any. Needs ks_load.
ks_get() { printf '%s\n' "$KS_MAP" | sed -n "s/^$1=//p"; }

# ks_set KEY NAME.sh: make KEY run the script, labelled with its name.
ks_set() {
    phone_set "fkey$(($1 - 1))=url $KS_URL$2" "fkey_label$(($1 - 1))=${2%.sh}" \
        "fkey_short_label$(($1 - 1))=${2%.sh}"
}

# ks_clear KEY: back to an ordinary line key.
ks_clear() {
    phone_set "fkey$(($1 - 1))=line" "fkey_label$(($1 - 1))=" "fkey_short_label$(($1 - 1))="
}
