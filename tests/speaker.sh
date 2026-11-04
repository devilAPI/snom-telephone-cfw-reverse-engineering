#!/usr/bin/env bash
# Network speaker / reverse intercom test (docs/speaker.md).
# Deploys the speaker and intercom files, starts both, plays a 1 kHz tone at about 5 %
# amplitude through spkstream and finds it in a recording made by micstream (the phone's
# own speakerphone mic). Checks the timing, that the intercom keeps its full frame rate
# while both run, the phone UI survives, and that stop cleans up (module, amxr
# connections, port, gains). Hostile CGI input is checked too.
#   NODEPLOY=1 tests/speaker.sh   skips the deploy step
set -u
. "$(dirname "$0")/lib.sh"
R=$REPO/custom-rootfs/snom/cfw
TMP=$(mktemp -d); trap 'rm -rf "$TMP" "$_askpass"' EXIT

deploy() {
    ph '/snom/cfw/intercom/speaker.sh stop; /snom/cfw/intercom/intercom.sh stop' >/dev/null 2>&1
    for f in intercom/spkstream intercom/micstream intercom/speaker.sh intercom/intercom.sh \
             intercom/amxr-mod.sh cgi-bin/speaker panel.d/91-speaker.html phone-menu.d/31-speaker; do
        ph_put "$R/$f" "/snom/cfw/$f"
    done
}
[ -n "${NODEPLOY:-}" ] || with_phone_lock deploy

# --- read-only checks ---
assert_contains "$(http /cgi-bin/panel)" 'Speaker / reverse intercom' "panel shows the speaker card"
assert_contains "$(ph 'wget -q -O - "http://127.0.0.1:8081/cgi-bin/phone-tools"')" 'speaker?a=phone' "phone-tools lists Speaker"
assert_contains "$(ph 'wget -q -O - "http://127.0.0.1:8081/cgi-bin/speaker?a=phone"')" '<IPPhoneMenu' "phone menu renders"
for q in 'a=%3Breboot' 'a=status%24(touch%20/tmp/pwned)' 'a=start&v=%24(id)' 'a=../../bin/sh' 'a=phone&do=%3Breboot'; do
    out=$(http "/cgi-bin/speaker?$q&fmt=txt")
    case "$out" in *running=*|*IPPhoneMenu*) pass "hostile query [$q] handled" ;; *) fail "hostile query [$q]: $out" ;; esac
done
assert_eq "" "$(ph 'ls /tmp/pwned 2>/dev/null')" "no command injection"

# 2 s of 1 kHz at 90 % of full scale; volume 22 makes that about 5 %
python3 - "$TMP/tone.raw" <<'PY'
import sys, math, array
a = array.array('h', (int(0.9 * 32767 * math.sin(2 * math.pi * 1000 * i / 16000)) for i in range(32000)))
open(sys.argv[1], 'wb').write(a.tobytes())
PY

play_test() {
    pids0=$(ph 'echo $(pidof lid) $(pidof media_daemon) $(pidof lcsD815)')
    st=$(http '/cgi-bin/speaker?a=start&fmt=txt&v=22')
    assert_contains "$st" 'running=1' "speaker start via CGI"
    tok=$(sed -n 's/^token=//p' <<<"$st")
    assert_eq 403 "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://$PHONE_IP:8091/status")" "no token: 403"
    assert_eq 403 "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://$PHONE_IP:8091/play?k=0" -d x)" "wrong token: 403"
    ic=$(http '/cgi-bin/intercom?a=start&fmt=txt&m=speaker')
    assert_contains "$ic" 'running=1' "intercom start"
    itok=$(sed -n 's/^token=//p' <<<"$ic")
    sleep 2   # spkstream switches to micstream's frame clock within a second
    curl -s -m 6 -o "$TMP/cap.raw" "http://$PHONE_IP:8090/raw?k=$itok" &
    sleep 1.5
    t0=$(date +%s%N)
    out=$(curl -s -m 10 --data-binary @"$TMP/tone.raw" "http://$PHONE_IP:8091/play?k=$tok&vol=22")
    t1=$(date +%s%N)
    wait
    assert_eq "played 2000 ms" "$out" "play answers when done"
    ms=$(( (t1 - t0) / 1000000 ))
    [ "$ms" -ge 1900 ] && [ "$ms" -le 3000 ] && pass "2 s sound took $ms ms" || fail "2 s sound took $ms ms"
    js=$(curl -s -m 5 "http://$PHONE_IP:8091/status?k=$tok")
    echo "status: $js"
    assert_contains "$js" '"underruns":0' "no underruns"
    pids1=$(ph 'echo $(pidof lid) $(pidof media_daemon) $(pidof lcsD815)')
    assert_eq "$pids0" "$pids1" "phone UI processes untouched"
    http '/cgi-bin/intercom?a=stop&fmt=txt' >/dev/null
    st=$(http '/cgi-bin/speaker?a=stop&fmt=txt')
    assert_contains "$st" 'running=0' "speaker stop via CGI"
    assert_eq "" "$(ph 'grep "^amxr_user_hook " /proc/modules')" "module unloaded"
    assert_eq "" "$(ph 'grep amxruser /proc/amxr | grep "cnxs=[1-9]"')" "no amxr connection left"
    assert_eq 000 "$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://$PHONE_IP:8091/status")" "port 8091 closed"
    assert_contains "$(http '/cgi-bin/speaker?a=stop&fmt=txt')" 'running=0' "second stop is harmless"
}
stop_now() { ph '/snom/cfw/intercom/speaker.sh stop; /snom/cfw/intercom/intercom.sh stop' >/dev/null; }
with_phone_lock play_test || { with_phone_lock stop_now; exit 1; }

python3 - "$TMP/cap.raw" <<'PY' || fail "tone not found in the recording"
import sys, array, cmath, math
a = array.array('h', open(sys.argv[1], 'rb').read())
secs = len(a) / 16000
print('recording: %.2f s' % secs)
assert secs > 5.5, 'intercom ran slow while the speaker was on: %.2f s in 6 s' % secs
def ratio(seg):
    # 1 kHz bin against the median of the 500..2000 Hz bins (DFT of 0.5 s, 2 Hz bins)
    n = len(seg); m = sum(seg) / n
    def mag(f): return abs(sum((seg[i] - m) * cmath.exp(-2j * math.pi * f * i / 16000) for i in range(0, n, 2)))
    ref = sorted(mag(f) for f in range(500, 2001, 50) if abs(f - 1000) > 60)
    return mag(1000) / ref[len(ref) // 2]
best = max(ratio(a[s:s + 8000]) for s in range(0, len(a) - 8000, 8000))
print('1 kHz peak / median: %.0f' % best)
assert best > 20, 'no tone in the recording'
PY
pass "tone played on the speaker and recorded by the mic; intercom at full rate"
echo "ALL SPEAKER TESTS PASSED"
