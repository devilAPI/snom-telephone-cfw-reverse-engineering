#!/bin/bash
# Task 0 test: panel assembles panel.d cards, phone-tools renders phone-menu.d, cfw_param decodes safely.
. "$(dirname "$0")/lib.sh"
SRC=$REPO/custom-rootfs/snom/cfw

deploy() {
    for f in lib/cfw.sh cgi-bin/panel cgi-bin/phone-tools cgi-bin/phone-games cgi-bin/phone-url index.html; do
        ph_put "$SRC/$f" "/snom/cfw/$f"
    done
    ph 'rm -rf /snom/cfw/panel.d /snom/cfw/phone-menu.d; mkdir -p /snom/cfw/panel.d /snom/cfw/phone-menu.d'
    for f in "$SRC"/panel.d/* "$SRC"/phone-menu.d/*; do
        ph_put "$f" "/snom/cfw/${f#$SRC/}"
    done
    # :8080 keeps running (CGIs are read per request); only the new loopback httpd is (re)started.
    # (pkill -f would match the ssh shell itself, hence the awk on ps)
    ph "kill \$(ps | awk '/[h]ttpd -p 127.0.0.1:8081/{print \$1}') 2>/dev/null; busybox httpd -p 127.0.0.1:8081 -h /snom/cfw; true"
}
with_phone_lock deploy

panel=$(http /cgi-bin/panel)
for t in "Reset root password" "Reset SSH config" "Boot Doom" "Boot NES" "Screenshot"; do
    assert_contains "$panel" "<h2>$t</h2>" "panel has card '$t'"
done
assert_contains "$(http /)" "url=/cgi-bin/panel" "index.html redirects to the panel"

tools=$(ph 'wget -qO- http://127.0.0.1:8081/cgi-bin/phone-tools')
assert_contains "$tools" "<IPPhoneMenu" "phone-tools returns IPPhoneMenu on :8081"
assert_contains "$tools" "http://127.0.0.1:8081/cgi-bin/phone-games" "menu entry points at :8081"
assert_contains "$(ph 'wget -qO- http://127.0.0.1:8081/cgi-bin/phone-games')" "<IPPhoneMenu" "phone-games works on :8081"

# cfw_param: GET decoding and no command substitution
out=$(ph "QUERY_STRING='x=1&a=a%20b%26c&b=%24(id)+%5Cx41' sh -c '. /snom/cfw/lib/cfw.sh; cfw_param a; echo; cfw_param b'")
assert_eq 'a b&c
$(id) \x41' "$out" "cfw_param decodes %20/%26, keeps \$(id) and backslashes literal"
# POST body
out=$(ph "printf 'a=p%%20q&z=1' | REQUEST_METHOD=POST CONTENT_LENGTH=11 QUERY_STRING= sh -c '. /snom/cfw/lib/cfw.sh; cfw_param a'")
assert_eq 'p q' "$out" "cfw_param reads POST body"
out=$(ph "QUERY_STRING='a=1' sh -c '. /snom/cfw/lib/cfw.sh; cfw_param \"a;id\"; echo rc=\$?'")
assert_eq 'rc=1' "$out" "cfw_param rejects a hostile NAME"
out=$(ph "sh -c '. /snom/cfw/lib/cfw.sh; printf \"%s\" \"<a href=\\\"x\\\">&\" | cfw_html_escape; echo; cfw_data_dir foundation-t; cfw_data_dir ../x; echo rc=\$?; rmdir /snom/cfw-data/foundation-t; cfw_rw; cfw_ro; cfw_game_running; echo game=\$?'")
assert_eq '&lt;a href=&quot;x&quot;&gt;&amp;
/snom/cfw-data/foundation-t
rc=1
game=1' "$out" "html_escape, data_dir (rejects ../), rw/ro no-op, no game running"
echo "ALL PASS"
