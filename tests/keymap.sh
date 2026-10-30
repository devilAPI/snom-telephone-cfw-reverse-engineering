#!/bin/bash
# Task L test: per-game key maps + volume keys (docs/keymap.md). Needs the phone; every game
# run holds the phone lock for the whole cycle (takeover + phone-restore). NES only for the
# engine side (the retro frontend and Doom share cfw_keymap.h and the same mapping code).
#  run A: game map swaps A/B (120 -> B) + one malformed line   -> log says "key 120 -> B", line ignored
#  run B: only default.map (120 -> SELECT)                      -> falls back to default.map
#  run C: no map at all                                         -> built-in ("key 120 -> A")
#  run D: tone.nes, stored volume 5 -> VOLUME_UP x2 -> file reads 25, PCM dump gets ~5x louder
#  plus the CGI: capture (game running + idle), save, reset, hostile input.
set -u
. "$(dirname "$0")/lib.sh"
C=$REPO/custom-rootfs/snom/cfw
ROMS=$REPO/tests/roms
PORT=${KM_PORT:-18767}
KM=/snom/cfw-data/keymaps/nes
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"; rm -f "$_askpass"' EXIT

deploy() {
    ph "rm -f /snom/cfw/nes/infones.new"
    ph_put "$REPO/tools/out/infones" /snom/cfw/nes/infones.new
    ph "mv /snom/cfw/nes/infones.new /snom/cfw/nes/infones"
    for f in lib/saves.sh cgi-bin/keymap panel.d/47-keymap.html bin/keyinject; do ph_put "$C/$f" "/snom/cfw/$f"; done
    ph 'mkdir -p /tmp/km-roms; netstat -ltn | grep -q "127.0.0.1:'$PORT' " || busybox httpd -p 127.0.0.1:'$PORT' -h /tmp/km-roms'
    for r in sav.nes tone.nes; do ph_put "$ROMS/$r" "/tmp/km-roms/$r"; done
}
wait_phone() {
    local i
    for i in $(seq 90); do
        [ "$(ph 'pidof lid >/dev/null && pidof lcsD375 >/dev/null && echo up')" = up ] && { sleep 20; return 0; }
        sleep 5
    done
    return 1
}
key() { ph "/snom/cfw/bin/keyinject $1 100"; }
# run ROM ENVS: start the NES launcher, return once the engine is up
start() { ph "$2 nohup /snom/cfw/nes/boot-nes.sh 'http://127.0.0.1:$PORT/$1' </dev/null >/dev/null 2>&1 &"; sleep 20; }
finish() { key F3; wait_phone || fail "phone app did not come back"; ph "cat /tmp/nes.log" > "$TMPD/nes.log"; }
peak() {  # peak FILE FROM_SAMPLE TO_SAMPLE
    python3 - "$@" <<'PY'
import sys, struct
d = open(sys.argv[1], 'rb').read()
a, b = int(sys.argv[2]) * 2, int(sys.argv[3]) * 2
s = struct.unpack('<%dh' % ((min(b, len(d)) - a) // 2), d[a:min(b, len(d))])
print(max(abs(x) for x in s) if s else 0)
PY
}

echo "== deploy"
with_phone_lock deploy
sha=$(ph "sha1sum /tmp/km-roms/sav.nes" | cut -d' ' -f1)
[ -n "$sha" ] || fail "no rom hash"

idle_capture() {
    ( sleep 2; ph 'printf "\0\0\0\0\0\0\0\0\001\0\146\0\001\0\0\0\0\0\0\0\0\0\0\0\001\0\146\0\0\0\0\0" > /dev/input/event0' ) &
    http "/cgi-bin/keymap?act=capture" | tr -d '\r\n '
    wait
}
echo "== idle capture (key code 102 is unmapped by lid, harmless)"
[ -n "${KM_CGI_ONLY:-}" ] || assert_eq 102 "$(with_phone_lock idle_capture)" "idle capture returns the injected scancode"

cycle() {
    ph "rm -rf $KM; mkdir -p $KM; printf '# swap A and B\n120 B\n116 A\nthis is garbage\n999 B\n97 NOSUCH\n97 START\n' > $KM/$sha.map; printf '120 SELECT\n' > $KM/default.map"
    echo "== run A: game map"
    start sav.nes "CFW_KEYMAP_DEBUG=1"
    ( http "/cgi-bin/keymap?act=capture" | tr -d '\r\n ' > "$TMPD/cap" ) & sleep 1; key F1; wait
    assert_eq 116 "$(cat "$TMPD/cap")" "capture while a game runs returns the last scancode"
    key ENTER; sleep 1
    finish
    L=$(cat "$TMPD/nes.log")
    assert_contains "$L" "keymap: $KM/$sha.map" "game map loaded"
    assert_contains "$L" "key 120 -> B" "ENTER (120) is B now"
    assert_contains "$L" "key 116 -> A" "F1 (116) is A now"
    assert_contains "$L" "$sha.map:4: ignoring malformed line" "malformed line logged"
    assert_contains "$L" "$sha.map:5: ignoring malformed line" "scancode out of range ignored"
    assert_contains "$L" "$sha.map:6: ignoring malformed line" "unknown action ignored"
    echo "== run B: default.map only"
    ph "rm -f $KM/$sha.map"
    start sav.nes "CFW_KEYMAP_DEBUG=1"; key ENTER; sleep 1; finish
    L=$(cat "$TMPD/nes.log")
    assert_contains "$L" "keymap: $KM/default.map" "fallback to default.map"
    assert_contains "$L" "key 120 -> SELECT" "default.map applies"
    echo "== run C: no map file"
    ph "rm -rf $KM"
    start sav.nes "CFW_KEYMAP_DEBUG=1"; key ENTER; sleep 1; finish
    L=$(cat "$TMPD/nes.log")
    assert_contains "$L" "keymap: built-in" "fallback to built-in"
    assert_contains "$L" "key 120 -> A" "built-in: ENTER is A"
    echo "== run D: volume keys"
    ph "echo 5 > /snom/cfw-data/volume"
    start tone.nes "SND_DUMP=1"
    n0=$(ph "wc -c < /tmp/snd_dump.raw"); sleep 1
    key VOLUME_UP; key VOLUME_UP; sleep 3
    n1=$(ph "wc -c < /tmp/snd_dump.raw")
    ph "cat /tmp/snd_dump.raw" > "$TMPD/dump.raw"
    assert_eq 25 "$(ph 'cat /snom/cfw-data/volume' | tr -d '\r\n ')" "volume file went 5 -> 25 after two VOLUME_UP"
    key VOLUME_DOWN; sleep 1
    assert_eq 15 "$(ph 'cat /snom/cfw-data/volume' | tr -d '\r\n ')" "VOLUME_DOWN steps back by 10"
    finish
    assert_contains "$(cat "$TMPD/nes.log")" "volume: 25%" "volume change logged"
    ph "rm -f /snom/cfw-data/volume /tmp/snd_dump.raw"
    p0=$(peak "$TMPD/dump.raw" 8000 $((n0 / 2 - 100)))
    p1=$(peak "$TMPD/dump.raw" $((n0 / 2 + 24000)) $((n1 / 2)))
    echo "  peak before=$p0 after=$p1"
    [ "$p0" -gt 0 ] && [ $((p1 * 10 / p0)) -ge 35 ] && [ $((p1 * 10 / p0)) -le 65 ] \
        && pass "PCM amplitude scaled ~5x (5% -> 25%)" || fail "PCM amplitude ratio off"
}
[ -n "${KM_CGI_ONLY:-}" ] || with_phone_lock cycle || exit 1

echo "== CGI"
page=$(http "/cgi-bin/keymap?eng=nes&game=default")
assert_contains "$page" "Volume +" "editor lists phone keys"
assert_contains "$(http /cgi-bin/panel)" "<h2>Key maps</h2>" "panel has the key map card"
r=$(curl -s -d act=save -d eng=gba -d game=default -d k51=A -d k48=BOGUS -d k119=VOLUP -d k16=VOLDOWN "http://$PHONE_IP:8080/cgi-bin/keymap")
assert_contains "$r" "Saved gba/default" "save reports success"
got=$(ph 'grep -v "^#" /snom/cfw-data/keymaps/gba/default.map' | tr -d '\r' | sort -n | tr '\n' '|')
assert_eq "16 VOLDOWN|51 A|119 VOLUP|" "$got" "save writes only valid assignments (BOGUS dropped)"
assert_contains "$(http '/cgi-bin/keymap?eng=gba&game=default')" '<option selected>A</option>' "editor shows the saved action"
r=$(curl -s -d act=save -d eng=nes -d 'game=../../evil' -d k51=A "http://$PHONE_IP:8080/cgi-bin/keymap")
assert_contains "$r" "Invalid game id" "hostile game id rejected"
assert_eq "" "$(ph 'ls /snom/cfw-data/evil.map /snom/cfw-data/keymaps/nes/evil* 2>/dev/null')" "nothing written outside the keymap dir"
r=$(curl -s -d act=save -d 'eng=../x' -d game=default -d k51=A "http://$PHONE_IP:8080/cgi-bin/keymap")
assert_eq "" "$(ph 'ls /snom/cfw-data/keymaps/../x* /snom/cfw-data/x* 2>/dev/null')" "hostile engine writes nothing"
r=$(curl -s -d act=reset -d eng=gba -d game=default "http://$PHONE_IP:8080/cgi-bin/keymap")
assert_contains "$r" "removed" "reset removes the map"
ph 'rm -rf /snom/cfw-data/keymaps; rm -rf /tmp/km-roms; for p in $(ps | grep "[h]ttpd -p 127.0.0.1:'$PORT'" | awk "{print \$1}"); do kill $p; done'
echo "ALL PASS"
