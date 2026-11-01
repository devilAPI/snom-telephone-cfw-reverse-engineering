#!/usr/bin/env bash
# Task G test: intercom / baby monitor (docs/intercom.md).
# Deploys the intercom files, starts the stream through the panel CGI, records 5 s on
# the host, checks it is a valid 16 kHz mono S16LE WAV with non-silent energy (ambient
# room noise; no tone is played), checks the phone UI survived, then stops and checks
# that the amxr tap, the module and the port are gone. Hostile CGI input is checked too.
#   NODEPLOY=1 tests/intercom.sh   skips the deploy step
set -u
. "$(dirname "$0")/lib.sh"
R=$REPO/custom-rootfs/snom/cfw
TMP=$(mktemp -d); trap 'rm -rf "$TMP" "$_askpass"' EXIT

deploy() {
    ph 'mkdir -p /snom/cfw/intercom'
    ph_put "$R/intercom/micstream"     /snom/cfw/intercom/micstream
    ph_put "$R/intercom/intercom.sh"   /snom/cfw/intercom/intercom.sh
    ph_put "$R/cgi-bin/intercom"       /snom/cfw/cgi-bin/intercom
    ph_put "$R/panel.d/90-intercom.html" /snom/cfw/panel.d/90-intercom.html
    ph_put "$R/phone-menu.d/30-intercom" /snom/cfw/phone-menu.d/30-intercom
}
[ -n "${NODEPLOY:-}" ] || with_phone_lock deploy
# the loopback httpd only exists on images with the Task 0 rcS; start it by hand if missing
ensure_8081() {
    ph 'netstat -ltn 2>/dev/null | grep -q "127.0.0.1:8081 " || busybox httpd -p 127.0.0.1:8081 -h /snom/cfw'
}
with_phone_lock ensure_8081

# --- read-only checks (no lock) ---
assert_contains "$(http /cgi-bin/panel)" 'Intercom / baby monitor' "panel shows the intercom card"
assert_contains "$(ph 'wget -q -O - "http://127.0.0.1:8081/cgi-bin/phone-tools"')" 'intercom?a=phone' "phone-tools lists Intercom"
assert_contains "$(ph 'wget -q -O - "http://127.0.0.1:8081/cgi-bin/intercom?a=phone"')" '<IPPhoneMenu' "phone menu renders"

# hostile input: never executed, never breaks the output
for q in 'a=%3Breboot' 'a=status%24(touch%20/tmp/pwned)' 'a=start%0Aid&g=%24(id)' 'a=../../bin/sh'; do
    out=$(http "/cgi-bin/intercom?$q&fmt=txt")
    assert_contains "$out" 'running=' "hostile query [$q] handled"
done
out=$(http '/cgi-bin/intercom?a=status&fmt=%22%3E%3Cscript%3Ex')
case "$out" in *'<script>x'*) fail "unescaped fmt reflected" ;; *) pass "fmt is not reflected" ;; esac
assert_eq "" "$(ph 'ls /tmp/pwned 2>/dev/null')" "no command injection"

# --- the stream (disruptive: insmod, codec gain, amxr tap) ---
stream_test() {
    pids0=$(ph 'echo $(pidof lid) $(pidof media_daemon) $(pidof lcsD375)')
    st=$(http '/cgi-bin/intercom?a=start&fmt=txt')
    echo "$st" | sed 's/^token=.*/token=(hidden)/'
    assert_contains "$st" 'running=1' "start via CGI"
    tok=$(sed -n 's/^token=//p' <<<"$st")
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://$PHONE_IP:8090/stream.wav")
    assert_eq 403 "$code" "stream without token is refused"
    curl -s -m 5 -o "$TMP/a.wav" "http://$PHONE_IP:8090/stream.wav?k=$tok"
    # a second listener at the same time
    curl -s -m 2 -o "$TMP/b.raw" "http://$PHONE_IP:8090/raw?k=$tok"
    lvl=$(http '/cgi-bin/intercom?a=status&fmt=json')
    echo "status json: $(sed 's/"token":"[0-9a-f]*"/"token":"(hidden)"/' <<<"$lvl")"
    pids1=$(ph 'echo $(pidof lid) $(pidof media_daemon) $(pidof lcsD375)')
    assert_eq "$pids0" "$pids1" "phone UI processes untouched while streaming"
    st=$(http '/cgi-bin/intercom?a=stop&fmt=txt')
    assert_contains "$st" 'running=0' "stop via CGI"
    assert_eq "" "$(ph 'grep "^amxr_user_hook " /proc/modules')" "module unloaded"
    assert_eq "" "$(ph 'grep amxruser /proc/amxr | grep -- "->"')" "no amxr tap left"
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://$PHONE_IP:8090/stream.wav")
    assert_eq 000 "$code" "port 8090 closed after stop"
    st=$(http '/cgi-bin/intercom?a=stop&fmt=txt')
    assert_contains "$st" 'running=0' "second stop is harmless"
}
stop_now() { ph "/snom/cfw/intercom/intercom.sh stop" >/dev/null; }
with_phone_lock stream_test || { with_phone_lock stop_now; exit 1; }

python3 - "$TMP/a.wav" "$TMP/b.raw" <<'EOF' || fail "stream content"
import sys, struct, array, math
d = open(sys.argv[1], 'rb').read()
assert d[:4] == b'RIFF' and d[8:16] == b'WAVEfmt ', 'no WAV header'
fmt, ch, rate, _, _, bits = struct.unpack('<HHIIHH', d[20:36])
assert (fmt, ch, rate, bits) == (1, 1, 16000, 16), (fmt, ch, rate, bits)
assert d[36:40] == b'data', 'no data chunk'
a = array.array('h', d[44:44 + (len(d) - 44) // 2 * 2])
secs = len(a) / 16000
m = sum(a) / len(a)
rms = math.sqrt(sum((x - m) ** 2 for x in a) / len(a))
print('wav: %.2f s, mean %.1f, rms %.1f, peak %d, distinct %d' % (secs, m, rms, max(map(abs, a)), len(set(a))))
assert secs > 3.5, 'too short: %.2f s' % secs
assert rms > 2 and len(set(a)) > 50, 'silent capture (mic muted?)'
assert abs(m) < 300, 'DC offset %.0f (DC blocker broken?)' % m
b = open(sys.argv[2], 'rb').read()
assert len(b) > 16000, 'second listener got only %d bytes' % len(b)
print('raw listener: %d bytes' % len(b))
EOF
pass "5 s stream is valid 16 kHz mono PCM with ambient energy; 2nd listener works"
echo "ALL INTERCOM TESTS PASSED"
