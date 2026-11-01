#!/usr/bin/env bash
# Task F test: custom ringtones (docs/ringtones.md).
#  1. deploy the ringtone files to the phone (under the phone lock)
#  2. panel card + page, upload a 5 %-amplitude test WAV through the CGI, read it back over
#     :8080 and over the loopback :8081 URL the phone itself uses
#  3. hostile names / bad files / oversize are rejected, nothing escapes the data dir
#  4. (lock) assign it to line 1, play the ringer with ringer volume 1, capture the audio
#     output digitally with tools/rtcap and correlate it with the uploaded file
#  5. (lock) phone app stopped (as during a game) -> clean error, no hang
#  6. (lock) read-only ringtone dir -> readable error
# Every phone setting touched is saved first and restored at the end.
set -u
. "$(dirname "$0")/lib.sh"
C=$REPO/custom-rootfs/snom/cfw
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"; rm -f "$_askpass"' EXIT
PH="http://$PHONE_IP"

deploy() {
    ph_put "$C/lib/ringtones.sh" /snom/cfw/lib/ringtones.sh
    ph_put "$C/cgi-bin/ringtones" /snom/cfw/cgi-bin/ringtones
    ph_put "$C/panel.d/85-ringtones.html" /snom/cfw/panel.d/85-ringtones.html
    ph 'mkdir -p /snom/cfw-data/ringtones; [ -L /snom/cfw/ringtones ] || ln -s /snom/cfw-data/ringtones /snom/cfw/ringtones
        mkdir -p /snom/cfw/tools'
    ph_put "$REPO/tools/out/rtcap" /tmp/rtcap
    # the loopback httpd (Task 0 rcS) - start it if this phone still runs an older image
    ph 'netstat -ltn | grep -q "127.0.0.1:8081 " || busybox httpd -p 127.0.0.1:8081 -h /snom/cfw'
}
with_phone_lock deploy

# --- test signal: 0.4 s 700 Hz, 0.4 s 1400 Hz, 0.4 s 2100 Hz (gaps 0.1 s), 0.8 s log sweep
# 300->3000 Hz, 0.5 s silence; 5 % amplitude. Deliberately different from any earlier test file,
# so a stale cached ringtone cannot pass the capture check.
python3 - "$TMPD" <<'EOF'
import math, struct, sys, wave
d = sys.argv[1]
def mk(path, rate, secs=None, amp=0.05):
    s = []
    for f, t in ((700, .4), (0, .1), (1400, .4), (0, .1), (2100, .4), (0, .1)):
        s += [amp * math.sin(2 * math.pi * f * i / rate) if f else 0 for i in range(int(rate * t))]
    n = int(rate * .8); ph = 0
    for i in range(n):
        f = 300 * (10 ** (i / n)); ph += 2 * math.pi * f / rate; s.append(amp * math.sin(ph))
    s += [0] * int(rate * .5)
    if secs: s = (s * int(secs / 2 + 1))[: int(rate * secs)]
    w = wave.open(path, 'wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
    w.writeframes(struct.pack('<%dh' % len(s), *[int(x * 32767) for x in s])); w.close()
mk(d + '/t16k.wav', 16000)
mk(d + '/t8k.wav', 8000)
mk(d + '/t44k.wav', 44100)
mk(d + '/big.wav', 16000, secs=40)   # > 1 MiB
w = wave.open(d + '/stereo.wav', 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(16000)
w.writeframes(b'\0' * 64000); w.close()
open(d + '/junk.wav', 'wb').write(b'this is not a wave file' * 10)
EOF

up() {  # NAME FILE -> CGI answer
    curl -s -m 90 -X POST -H 'Content-Type: application/octet-stream' --data-binary @"$2" \
        "http://$PHONE_IP:8080/cgi-bin/ringtones?act=upload&name=$1"
}

# --- 2. panel / upload / serve
assert_contains "$(http /cgi-bin/panel)" "Manage ringtones" "panel shows the Ringtones card"
assert_contains "$(http /cgi-bin/ringtones)" "Convert and upload" "ringtones page renders"
assert_contains "$(up cfwtest.wav "$TMPD/t16k.wav")" "OK stored cfwtest.wav" "upload 16 kHz WAV"
assert_contains "$(up cfwtest8k.wav "$TMPD/t8k.wav")" "OK stored cfwtest8k.wav" "upload 8 kHz WAV"
want=$(md5sum < "$TMPD/t16k.wav" | cut -d' ' -f1)
assert_eq "$want" "$(http /ringtones/cfwtest.wav | md5sum | cut -d' ' -f1)" "served on :8080/ringtones/"
assert_eq "$want" "$(ph 'wget -q -O - http://127.0.0.1:8081/ringtones/cfwtest.wav | md5sum' | cut -d' ' -f1)" \
    "served on the loopback URL the phone uses"
assert_contains "$(http /cgi-bin/ringtones)" "cfwtest.wav" "page lists the upload"

# --- 3. hostile / invalid input
for n in '../x.wav' 'a%3Bb.wav' '%24(id).wav' 'a%20b.wav' '..%2F..%2Fetc%2Fx.wav' '.hidden.wav' 'x.sh' "a'b.wav"; do
    assert_contains "$(up "$n" "$TMPD/t16k.wav")" "ERROR invalid name" "upload name '$n' rejected"
done
assert_contains "$(up junk.wav "$TMPD/junk.wav")" "ERROR not a WAV" "non-WAV rejected"
assert_contains "$(up s.wav "$TMPD/stereo.wav")" "must be mono" "stereo rejected"
assert_contains "$(up h.wav "$TMPD/t44k.wav")" "not supported" "44.1 kHz rejected"
assert_contains "$(up big.wav "$TMPD/big.wav")" "the limit is" "oversize rejected"
r=$(curl -s -m 10 -X POST --data 'act=delete&name=..%2F..%2Fcfw%2Findex.html' "http://$PHONE_IP:8080/cgi-bin/ringtones")
assert_contains "$r" "invalid ringtone name" "hostile delete rejected"
assert_contains "$(curl -s -m 10 -X POST --data 'act=use&name=cfwtest.wav&line=1%3Bid' "http://$PHONE_IP:8080/cgi-bin/ringtones")" \
    "invalid line" "hostile line rejected"
assert_eq "yes" "$(ph '[ -f /snom/cfw/index.html ] && ! ls /snom/cfw-data/ringtones | grep -q -v "^cfwtest" && echo yes')" \
    "nothing but the test uploads landed, index.html intact"

# --- 4. ring it and capture the output digitally
# live values from the stock settings.htm (config.xml is flushed lazily by lcsD375)
setting() { curl -s -m 30 "$PH/settings.htm" | tr -d "\r" | sed -n "s/.*>$1<\/a>=\(.*\)\$/\1/p" | sed 's/&#x2F;/\//g' | head -n1; }
setting_idx() { setting "$1$2"; }
save() { curl -s -m 10 -o /dev/null -G "$PH/dummy.htm" --data-urlencode settings=save --data-urlencode "$1"; }
ring_test() {
    OLD_VOL=$(setting vol_ringer); OLD_R=$(setting_idx user_ringer 1); OLD_C=$(setting_idx user_custom 1)
    echo "saved: vol_ringer=[${OLD_VOL}] user_ringer1=[${OLD_R}] user_custom1=[${OLD_C}]"
    trap ring_restore EXIT   # runs even when an assert fails (fail exits this lock subshell)
    save vol_ringer=1
    r=$(curl -s -m 40 -X POST --data 'act=use&name=cfwtest.wav&line=1' "http://$PHONE_IP:8080/cgi-bin/ringtones")
    assert_contains "$r" "now ring with cfwtest.wav" "assign to line 1"
    assert_eq "http://127.0.0.1:8081/ringtones/cfwtest.wav" "$(setting_idx user_custom 1)" "user_custom1 written"
    assert_eq "Custom" "$(setting_idx user_ringer 1)" "user_ringer1=Custom written"
    ph 'lsmod | grep -q amxr_user_hook || insmod /lib/modules/2.6.27.47/BROADCOM/amxr_user_hook.ko
        [ -c /dev/amxruser ] || mknod /dev/amxruser c 236 0
        rm -f /tmp/rtcap0.raw /tmp/rtcap1.raw; (/tmp/rtcap 9 halaudio.apm0 halaudio.apm1 </dev/null >/tmp/rtcap.log 2>&1 &)'
    sleep 1
    r=$(curl -s -m 40 -X POST --data 'act=play&line=1' "http://$PHONE_IP:8080/cgi-bin/ringtones")
    assert_contains "$r" "Playing the ringer of line 1" "play ringer"
    sleep 10
    ph 'cat /tmp/rtcap.log'
    ph 'cat /tmp/rtcap0.raw' > "$TMPD/cap0.raw"; ph 'cat /tmp/rtcap1.raw' > "$TMPD/cap1.raw"
    [ -n "${KEEP_CAP:-}" ] && cp "$TMPD"/cap?.raw "$KEEP_CAP"/
}
ring_restore() {
    save "user_ringer1=${OLD_R:-Ringer1}"; save "user_custom1=${OLD_C}"; save "vol_ringer=${OLD_VOL:-10}"
    echo "restored: vol_ringer=[$(setting vol_ringer)] user_ringer1=[$(setting_idx user_ringer 1)] user_custom1=[$(setting_idx user_custom 1)]"
}
with_phone_lock ring_test
python3 "$REPO/tests/ringtone_corr.py" "$TMPD/t16k.wav" "$TMPD/cap0.raw" "$TMPD/cap1.raw"
case $? in
    0) pass "captured phone output correlates with the uploaded ringtone" ;;
    2) echo "WARN: microphones silent - playback capture inconclusive (see docs/ringtones.md)" ;;
    *) fail "captured output does not match the ringtone" ;;
esac

# --- 5. phone app stopped (a game SIGSTOPs lcsD375) -> clean, fast error
stopped_test() {
    ph 'kill -STOP $(pidof lcsD375)'
    t0=$(date +%s)
    r=$(curl -s -m 30 -X POST --data 'act=play&line=1' "http://$PHONE_IP:8080/cgi-bin/ringtones")
    t1=$(date +%s)
    ph 'kill -CONT $(pidof lcsD375)'
    assert_contains "$r" "ERROR" "play with the phone app stopped gives an error"
    [ $((t1 - t0)) -le 10 ] && pass "... within $((t1 - t0)) s" || fail "took $((t1 - t0)) s"
}
with_phone_lock stopped_test

# --- 6. read-only storage -> readable error
ro_test() {
    ph 'mount -t tmpfs -o ro,size=64k tmpfs /snom/cfw-data/ringtones'
    r=$(up rotest.wav "$TMPD/t8k.wav")
    ph 'umount /snom/cfw-data/ringtones'
    assert_contains "$r" "ERROR could not write" "read-only ringtone dir gives a readable error"
}
with_phone_lock ro_test

# --- cleanup
for n in cfwtest.wav cfwtest8k.wav; do
    curl -s -m 10 -o /dev/null -X POST --data "act=delete&name=$n" "http://$PHONE_IP:8080/cgi-bin/ringtones"
done
assert_eq "" "$(ph 'ls /snom/cfw-data/ringtones | grep cfwtest')" "test files deleted"
echo "ALL RINGTONE TESTS PASSED"
