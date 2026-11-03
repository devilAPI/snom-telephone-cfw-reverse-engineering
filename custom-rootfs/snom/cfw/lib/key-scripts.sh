# CFW scripts on the phone's programmable keys. Source after phone-web.sh and
# scripts-run.sh. A key runs a script through the phone's own "url" key function,
# so it stays an ordinary key that can be seen and changed in the phone's settings.
# Keys are numbered 1 to 12, as printed on the phone; the settings count from 0.
KS_KEYS="1 2 3 4 5 6 7 8 9 10 11 12"
KS_URL=http://127.0.0.1:8081/cgi-bin/key-script?run=
KG_URL=http://127.0.0.1:8081/cgi-bin/key-game?
KG_SYSTEMS="doom nes gb gba"

# ks_load: fill KS_MAP with "KEY=NAME.sh" lines for the keys that run a script, and
# KG_MAP with "KEY=SYS URL" lines for the keys that start a game (see key-game).
# settings.xml, because settings.htm takes the phone about 20 s to go through.
ks_load() {
    phone_admin
    _ks=$(phone_curl -s -m 15 "$PHONE_WEB/settings.xml" </dev/null | tr -d '\r' |
        sed -n 's|^<fkey idx="\([0-9]*\)"[^>]*>url \(http://127.0.0.1:8081/cgi-bin/key-[a-z]*?[^<]*\)</fkey>.*|\1 \2|p' |
        sed 's/&amp;/\&/g')
    KS_MAP=$(printf '%s\n' "$_ks" | sed -n "s|^\([0-9]*\) $KS_URL\(.*\)|\1 \2|p" |
        while read -r _i _n; do echo "$((_i + 1))=$_n"; done)
    KG_MAP=$(printf '%s\n' "$_ks" | sed -n "s|^\([0-9]*\) ${KG_URL}sys=\([a-z]*\)&url=\(.*\)|\1 \2 \3|p" |
        while read -r _i _s _u; do echo "$((_i + 1))=$_s $(printf '%s' "$_u" | cfw_urldecode)"; done)
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

# kg_get KEY: "SYS URL" of the game on KEY, if any. Needs ks_load.
kg_get() { printf '%s\n' "$KG_MAP" | sed -n "s/^$1=//p"; }

# kg_label URL: a key label from a game URL: the file name without its extension.
kg_label() {
    _b=${1%%\?*}; _b=${_b%/}; _b=${_b##*/}
    _b=$(printf '%s' "$_b" | cfw_urldecode | sed 's/%2[fF]/\//g; s|.*/||')
    printf '%s' "${_b%.*}" | cut -c1-20
}

# kg_set KEY SYS URL: make KEY start the game, labelled with its file name.
kg_set() {
    _e=$(printf '%s' "$3" | sed 's/%/%25/g; s/&/%26/g; s/ /%20/g; s/?/%3F/g; s/=/%3D/g; s/#/%23/g; s/+/%2B/g')
    _l=$(kg_label "$3")
    phone_set "fkey$(($1 - 1))=url ${KG_URL}sys=$2&url=$_e" "fkey_label$(($1 - 1))=$_l" \
        "fkey_short_label$(($1 - 1))=$_l"
}
