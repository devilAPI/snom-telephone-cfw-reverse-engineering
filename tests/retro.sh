#!/bin/bash
# Task E test: GB/GBC + GBA emulators (libretro frontend), launchers, CGIs.
#
#   tests/retro.sh            deploy + launcher/CGI checks (bad URL, non-ROM,
#                             hostile input, phone menu) - no screen takeover
#   RETRO_RUN=1 tests/retro.sh  additionally boots each test ROM end to end
#                             (launcher downloads it from a loopback httpd on the phone),
#                             checks the screenshot, *_STATS fps >= 55,
#                             underruns, the SND_DUMP tones (FFT), the L/R
#                             keys, then quits with the hangup key and waits
#                             for the phone app. One takeover per system.
#
# Test ROMs: tests/roms (hand-made, see tests/roms/build.sh).
. "$(dirname "$0")/lib.sh"
SRC=$REPO/custom-rootfs/snom/cfw
ROMS=$REPO/tests/roms
OUTD=${RETRO_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/retro-test.XXXXXX")}
mkdir -p "$OUTD"

# POST to the panel (Basic auth is ignored if the panel has no login).
post() { curl -s -m 40 -u "root:$PHONE_PW" --data-urlencode "url=$2" "http://$PHONE_IP:8080$1"; }
hget() { curl -s -m 40 -u "root:$PHONE_PW" "http://$PHONE_IP:8080$1"; }

deploy() {
    for f in gba/gpsp gb/gambatte; do
        ph "rm -f /snom/cfw/$f.new"
        ph_put "$REPO/tools/out/${f#*/}" "/snom/cfw/$f.new"
        ph "mv /snom/cfw/$f.new /snom/cfw/$f"
    done
    for f in lib/retro-boot.sh gba/boot-gba.sh gb/boot-gb.sh cgi-bin/boot-gba cgi-bin/boot-gb \
             cgi-bin/phone-retro cgi-bin/phone-games panel.d/45-gba.html panel.d/46-gb.html; do
        ph_put "$SRC/$f" "/snom/cfw/$f"
    done
    # Images older than Task 0's rcS have no loopback httpd for the phone menus.
    ph "netstat -ltn | grep -q '127.0.0.1:8081 ' || busybox httpd -p 127.0.0.1:8081 -h /snom/cfw; true"
}
echo "== deploy"
with_phone_lock deploy

echo "== panel + phone menu"
panel=$(hget /cgi-bin/panel)
assert_contains "$panel" "<h2>Boot GBA</h2>" "panel has the GBA card"
assert_contains "$panel" "<h2>Boot Game Boy / Color</h2>" "panel has the GB card"
games=$(ph 'wget -qO- http://127.0.0.1:8081/cgi-bin/phone-games')
assert_contains "$games" "phone-games?game=gba" "Games menu lists GBA"
assert_contains "$games" "phone-games?game=gb" "Games menu lists Game Boy"
sub=$(ph 'wget -qO- "http://127.0.0.1:8081/cgi-bin/phone-games?game=gb"')
assert_contains "$sub" "phone-retro?sys=gb" "GB submenu has Enter URL"
inp=$(ph 'wget -qO- "http://127.0.0.1:8081/cgi-bin/phone-retro?sys=gba"')
assert_contains "$inp" "<IPPhoneInput" "phone-retro URL entry"
assert_contains "$inp" "phone-retro?sys=gba&amp;url=__U__" "URL entry submits to phone-retro"

echo "== bad input (nothing may take over the screen)"
lid_before=$(ph 'pidof lid')
r=$(post /cgi-bin/boot-gba 'ftp://example.com/x.gba')
assert_contains "$r" "valid http:// or https:// URL" "GBA: non-http URL rejected"
r=$(post /cgi-bin/boot-gb 'http://127.0.0.1:1/nothing.gb')
assert_contains "$r" "Not started: download failed" "GB: unreachable URL reported"
r=$(post /cgi-bin/boot-gba 'http://127.0.0.1:8081/index.html')
assert_contains "$r" "Not started: not a GBA ROM" "GBA: non-ROM file reported"
r=$(post /cgi-bin/boot-gb 'http://127.0.0.1:8081/index.html')
assert_contains "$r" "Not started: not a GB/GBC ROM" "GB: non-ROM file reported"
ph 'rm -f /tmp/pwned*'
r=$(post /cgi-bin/boot-gba 'http://127.0.0.1:1/$(touch /tmp/pwned1)`touch /tmp/pwned2`;touch /tmp/pwned3;"x y"/../../x.gba')
assert_contains "$r" "Not started" "GBA: hostile URL is just a failed download"
assert_eq "" "$(ph 'ls /tmp/pwned* 2>/dev/null')" "hostile URL ran no command"
r=$(ph "wget -qO- 'http://127.0.0.1:8081/cgi-bin/phone-retro?sys=gb&url=javascript:x'")
assert_contains "$r" "Invalid URL" "phone-retro: bad URL"
r=$(ph "wget -qO- 'http://127.0.0.1:8081/cgi-bin/phone-retro?sys=gba&url=http%3A%2F%2F127.0.0.1%3A8081%2Findex.html'")
assert_contains "$r" "not a GBA ROM" "phone-retro: non-ROM reported on the phone"
r=$(ph "wget -qO- 'http://127.0.0.1:8081/cgi-bin/phone-retro?sys=x%3Bid'")
assert_contains "$r" "Unknown system" "phone-retro: unknown system"
assert_eq "$lid_before" "$(ph 'pidof lid')" "phone app untouched by all of the above"
log=$(hget '/cgi-bin/boot-gba?log=1')
assert_contains "$log" "Status: error" "launcher log page shows the last error"

[ "${RETRO_RUN:-}" = 1 ] || { echo "ALL PASS (set RETRO_RUN=1 for the on-screen runs)"; exit 0; }

# ---------------------------------------------------------------- end to end
# Serve the test ROMs from the phone itself (a throw-away busybox httpd on
# loopback), so no host firewall is in the way.
PORT=${RETRO_PORT:-18765}
HOSTIP=127.0.0.1
serve_roms() {  # (again after a reboot: /tmp is RAM)
    ph "netstat -ltn | grep -q '127.0.0.1:$PORT '" && return 0
    ph 'mkdir -p /tmp/retro-roms'
    ph_put "$ROMS/sndtest.gba" /tmp/retro-roms/sndtest.gba
    ph_put "$ROMS/sndtest.gb" /tmp/retro-roms/sndtest.gb
    ph "busybox httpd -p 127.0.0.1:$PORT -h /tmp/retro-roms"
}
kill_srv() { ph "for p in \$(ps | grep '[h]ttpd -p 127.0.0.1:$PORT' | awk '{print \$1}'); do kill \$p; done"; rm -f "$_askpass"; }
trap kill_srv EXIT

wait_phone() {  # until lid + lcsD375 run again (restore or reboot), then settle
    local i
    for i in $(seq 90); do
        [ "$(ph 'pidof lid >/dev/null && pidof lcsD375 >/dev/null && echo up')" = up ] && { sleep 20; return 0; }
        sleep 5
    done
    return 1
}

# run_one SYS ROM STATSVAR
run_one() {
    local sys=$1 rom=$2 env=$3
    ph "rm -f /tmp/snd_dump.raw /tmp/$sys.log"
    serve_roms
    ph "$env=1 SND_VOL=5 SND_DUMP=1 nohup /snom/cfw/$sys/boot-$sys.sh 'http://$HOSTIP:$PORT/$rom' </dev/null >/dev/null 2>&1 &"
    sleep 22
    curl -s -m 20 "http://$PHONE_IP:8080/cgi-bin/screenshot" -u "root:$PHONE_PW" > "$OUTD/$sys.bmp"
    # L (digit 1 = 51), R (digit 3 = 48) are mapped; digit 2 (49) must show up as unmapped.
    ph 'for c in 51 48 49; do o=$(printf %03o $c); for v in 001 0; do printf "\0\0\0\0\0\0\0\0\001\0\\$o\0\\$v\0\0\0" > /dev/input/event0; usleep 80000; done; done'
    sleep 10
    ph "cat /tmp/snd_dump.raw" > "$OUTD/$sys.raw"
    # hangup (114) quits. Release first: the kernel drops a press for a key it
    # already thinks is down (a stale injected press without release).
    ph 'for v in 0 001 0; do printf "\0\0\0\0\0\0\0\0\001\0\162\0\\$v\0\0\0" > /dev/input/event0; usleep 100000; done'
    sleep 3
    ph "cat /tmp/$sys.log" > "$OUTD/$sys.log"
}

check_one() {
    local sys=$1 const=$2 arp=$3
    echo "-- $sys log:"; sed 's/^/   /' "$OUTD/$sys.log"
    local fps
    fps=$(sed -n "s/^$sys: \([0-9]*\)\.[0-9] fps.*/\1/p" "$OUTD/$sys.log" | sed -n '2,$p' | sort -n | head -n 1)
    [ -n "$fps" ] || fail "$sys: no stats lines"
    [ "$fps" -ge 55 ] && pass "$sys: slowest 5 s window after start-up $fps fps (>= 55)" || fail "$sys: $fps fps"
    assert_contains "$(cat "$OUTD/$sys.log")" "$sys: unmapped key 49" "$sys: digit 2 logged as unmapped"
    case "$(cat "$OUTD/$sys.log")" in *"unmapped key 51"*|*"unmapped key 48"*) fail "$sys: L/R not mapped" ;; esac
    pass "$sys: digits 1/3 mapped (L/R)"
    python3 "$REPO/tests/fftcheck.py" "$OUTD/$sys.raw" "$const" "$arp" || fail "$sys: tones in the PCM dump"
    pass "$sys: expected tones in the PCM dump"
    python3 - "$OUTD/$sys.bmp" "$sys" <<'PY' || fail "$sys: screenshot"
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGB')
if sys.argv[2] == 'gba':   # 8 bars over 408 px at x=36
    want = [(255,0,0),(0,255,0),(0,0,255),(255,255,0),(0,255,255),(255,0,255),(255,255,255),(132,132,132)]
    xs = [36 + int(408 * (i + .5) / 8) for i in range(8)]
else:                      # 4 bars of 5 tiles over 302 px at x=89 (20 of 20 tiles)
    want = [(255,0,0),(0,255,0),(0,0,255),(255,255,255)]
    xs = [89 + int(302 * (i + .5) / 4) for i in range(4)]
bad = 0
for x, w in zip(xs, want):
    p = im.getpixel((x, 136))
    ok = all(abs(a - b) < 60 for a, b in zip(p, w))
    print('   x=%3d got %s want %s %s' % (x, p, w, 'ok' if ok else 'BAD'))
    bad += not ok
for x in (5, 474):
    p = im.getpixel((x, 136))
    print('   border x=%d %s' % (x, p)); bad += p != (0, 0, 0)
sys.exit(1 if bad else 0)
PY
    pass "$sys: screenshot shows the test pattern, black borders"
}

e2e() {
    run_one gba sndtest.gba GBA_STATS
    wait_phone || fail "gba: phone app did not come back"
    run_one gb sndtest.gb GB_STATS
    wait_phone || fail "gb: phone app did not come back"
}
echo "== end-to-end runs (screen takeover, under the phone lock)"
with_phone_lock e2e || fail "end-to-end run"
check_one gba 219.9 439.8,555.4,658.7,879.7,1110.8
check_one gb  219.9 439.8,555.4,658.7,879.7,1110.8
echo "artifacts: $OUTD"
echo "ALL PASS"
