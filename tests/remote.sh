#!/bin/bash
# Task J test: remote screen + keypad page. Deploys keyinject, fbshot and the CGIs
# under the phone lock, then checks the page, frames, frame rate, the key whitelist
# and that a key press visibly changes the screen.
. "$(dirname "$0")/lib.sh"
C=$REPO/custom-rootfs/snom/cfw
TMP=$(mktemp -d); trap 'rm -rf "$TMP"; rm -f "$_askpass"' EXIT

deploy() {
    for f in keyinject fbshot; do ph_put "$C/bin/$f" "/snom/cfw/bin/$f"; done
    for f in remote remote-key remote-frame; do ph_put "$C/cgi-bin/$f" "/snom/cfw/cgi-bin/$f"; done
    ph_put "$C/panel.d/55-remote.html" /snom/cfw/panel.d/55-remote.html
    ph_put "$C/lib/cfw.sh" /snom/cfw/lib/cfw.sh
    ph "chmod 755 /snom/cfw/bin/keyinject /snom/cfw/bin/fbshot /snom/cfw/cgi-bin/remote /snom/cfw/cgi-bin/remote-key /snom/cfw/cgi-bin/remote-frame; rm -f /tmp/pwned"
}
with_phone_lock deploy || exit 1

# --- page and panel card
H=$(http /cgi-bin/remote)
assert_contains "$H" "remote-frame" "remote page references the frame CGI"
assert_contains "$H" "remote-key" "remote page references the key CGI"
assert_contains "$(http /cgi-bin/panel)" "/cgi-bin/remote" "panel has the remote card"

# --- frames: header + size, per scale
frame() { curl -s -m 20 "http://$PHONE_IP:8080/cgi-bin/remote-frame?scale=$1" -o "$2"; }
for s in 1 2 4; do
    frame $s $TMP/f$s.bin
    w=$((480/s)); h=$((272/s))
    assert_eq $((8 + w*h*2)) "$(stat -c %s $TMP/f$s.bin)" "scale $s frame size ${w}x${h} RGB565"
    assert_eq "SF" "$(head -c 2 $TMP/f$s.bin)" "scale $s magic"
done
frame 7 $TMP/f7.bin
assert_eq $((8 + 240*136*2)) "$(stat -c %s $TMP/f7.bin)" "invalid scale falls back to 2"

# --- frame rate (sequential requests, like the page's polling loop)
for s in 1 2 4; do
    t0=$(date +%s.%N); n=12
    for i in $(seq $n); do frame $s $TMP/fr.bin; done
    t1=$(date +%s.%N)
    echo "FPS scale $s: $(python3 -c "print(round($n/($t1-$t0),1))") frames/s (sequential curl, includes connection setup)"
done

# --- whitelist / hostile input
keycode() { curl -s -o /dev/null -w '%{http_code}' -m 10 "http://$PHONE_IP:8080/cgi-bin/remote-key?$1"; }
assert_eq 400 "$(keycode 'key=%24%28touch%20/tmp/pwned%29')" 'key=$(touch) rejected'
assert_eq 400 "$(keycode 'key=%24%28reboot%29')" 'key=$(reboot) rejected'
assert_eq 400 "$(keycode 'key=UP%3Btouch%20/tmp/pwned')" 'key=UP;touch rejected'
assert_eq 400 "$(keycode 'key=..%2F..%2Fetc%2Fpasswd')" 'path traversal rejected'
assert_eq 400 "$(keycode 'key=FOO')" 'unknown key name rejected'
assert_eq 400 "$(keycode 'key=')" 'empty key rejected'
assert_eq 400 "$(keycode 'key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')" 'overlong key rejected'
assert_eq 400 "$(keycode 'key=UP&ms=abc')" 'non-numeric ms rejected'
assert_eq 400 "$(keycode 'key=UP&ms=99999')" 'huge ms rejected'
assert_eq 400 "$(keycode 'key=UP&ms=%24%28id%29')" 'ms=$(id) rejected'
assert_eq "gone" "$(ph '[ -e /tmp/pwned ] && echo exists || echo gone')" "no injected command ran"

# --- a key press changes the screen (idle phone UI): SETTINGS opens a menu, CANCEL closes it
press_test() {
    if ph 'for p in /proc/[0-9]*; do readlink $p/exe; done' | grep -q '^/snom/cfw/[a-z]*/'; then echo "SKIP: a game owns the screen"; return; fi
    curl -s -m 10 "http://$PHONE_IP:8080/cgi-bin/remote-key?key=CANCEL" >/dev/null; sleep 1
    curl -s -m 10 "http://$PHONE_IP:8080/cgi-bin/remote-key?key=CANCEL" >/dev/null; sleep 1
    frame 2 $TMP/before.bin
    assert_eq "ok SETTINGS" "$(curl -s -m 10 "http://$PHONE_IP:8080/cgi-bin/remote-key?key=SETTINGS")" "SETTINGS accepted"
    sleep 2; frame 2 $TMP/after.bin
    if cmp -s $TMP/before.bin $TMP/after.bin; then fail "screen unchanged after SETTINGS"; else pass "screen changed after SETTINGS key"; fi
    # restore the idle screen
    for i in 1 2 3; do curl -s -m 10 "http://$PHONE_IP:8080/cgi-bin/remote-key?key=CANCEL" >/dev/null; sleep 1; done
}
with_phone_lock press_test || exit 1
echo "remote test done"
exit 0
