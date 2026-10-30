#!/bin/bash
# Zip support for the game launchers (docs/zip.md).
#
#   tests/zip.sh     deploys the zip files to the phone, serves test zips from this
#                    PC (python http.server on the LAN IP), then checks the
#                    list/extract stage for every system without a screen
#                    takeover, hostile input, and finally THREE real runs
#                    (each under the phone lock, quit with the hangup key,
#                    phone restored via lib/phone-restore.sh):
#                      1. multi-ROM NES zip: the on-phone list, choice 2 runs sav.nes
#                      2. single GB ROM in a nested folder of a zip (+ __MACOSX junk)
#                      3. plain (non-zip) NES ROM still runs
#   Which ROM actually ran is read from the save file hash in the launcher log.
. "$(dirname "$0")/lib.sh"
SRC=$REPO/custom-rootfs/snom/cfw
ROMS=$REPO/tests/roms
HOSTIP=${ZIP_HOSTIP:-192.168.178.49}
PORT=${ZIP_PORT:-8000}   # the host firewall only lets the phone reach 8000 and 8080
W=$(mktemp -d "${TMPDIR:-/tmp}/zip-test.XXXXXX")
mkdir -p "$W/www"

hget() { curl -s -m 60 -u "root:$PHONE_PW" "http://$PHONE_IP:8080$1"; }
post() { curl -s -m 60 -u "root:$PHONE_PW" "$@"; }
pw()   { ph "wget -qO- '$1'"; }   # loopback phone menu CGIs
sha()  { sha1sum "$1" | cut -d' ' -f1; }

# ------------------------------------------------------------ test zips (host)
python3 - "$ROMS" "$W/www" <<'PY'
import sys, zipfile, os
r, w = sys.argv[1], sys.argv[2]
rd = lambda n: open(os.path.join(r, n), 'rb').read()
def z(name, entries):
    with zipfile.ZipFile(os.path.join(w, name), 'w', zipfile.ZIP_DEFLATED) as f:
        for n, d in entries: f.writestr(n, d)
z('multi-nes.zip', [('readme.txt', b'hi'), ('tone.nes', rd('tone.nes')), ('sub/sav.nes', rd('sav.nes')),
                    ('__MACOSX/._tone.nes', b'junk'), ('sub/._sav.nes', b'junk')])
z('nested-gb.zip', [('__MACOSX/pack/._sav.gb', b'junk'), ('pack/games/sav.gb', rd('sav.gb')), ('pack/notes.txt', b'x')])
z('multi-gb.zip', [('a.GB', rd('sav.gb')), ('deep/b.gbc', rd('sndtest.gb')), ('c.gba', rd('sav.gba'))])
z('none.zip', [('readme.txt', b'nothing here'), ('game.sfc', b'x'), ('__MACOSX/._x.nes', b'j')])
z('gba-none.zip', [('x.nes', rd('tone.nes'))])
z('multi-doom.zip', [('one.wad', b'IWAD\0\0\0\0\0\0\0\0MAP01'), ('d/TWO.WAD', b'IWAD\0\0\0\0\0\0\0\0E1M1')])
z('evil.zip', [('../../tmp/zip-evil-escape.nes', rd('tone.nes')), ('/tmp/zip-evil-abs.nes', rd('tone.nes')), ('ok.nes', rd('sav.nes'))])
open(os.path.join(w, 'tone.nes'), 'wb').write(rd('tone.nes'))
open(os.path.join(w, 'fake.nes'), 'wb').write(b'PK\x03\x04 but not a zip')   # zip magic, broken body
PY
( cd "$W/www" && exec python3 -m http.server "$PORT" --bind "$HOSTIP" >/dev/null 2>&1 ) &
SRV=$!
trap 'kill $SRV 2>/dev/null; rm -f "$_askpass"; rm -rf "$W"' EXIT
sleep 1
B=http://$HOSTIP:$PORT
code=$(ph "curl -s -m 10 -o /dev/null -w \"%{http_code}\" $B/multi-nes.zip"); [ "$code" = 200 ] || fail "the phone cannot reach $B (got [$code])"

# ------------------------------------------------------------------- deploy
deploy() {
    for f in bin/unzip lib/zip.sh lib/retro-boot.sh nes/boot-nes.sh doom/boot-doom.sh gb/boot-gb.sh gba/boot-gba.sh \
             cgi-bin/boot-nes cgi-bin/boot-doom cgi-bin/boot-gb cgi-bin/boot-gba cgi-bin/phone-boot \
             cgi-bin/phone-retro cgi-bin/phone-pick cgi-bin/phone-games; do
        ph_put "$SRC/$f" "/snom/cfw/$f"
    done
    ph "chmod 755 /snom/cfw/bin/unzip; netstat -ltn | grep -q '127.0.0.1:8081 ' || busybox httpd -p 127.0.0.1:8081 -h /snom/cfw; true"
}
echo "== deploy"
with_phone_lock deploy
assert_contains "$(ph '/snom/cfw/bin/unzip -l /dev/null 2>&1')" "Archive:" "static unzip runs on the phone"

# ------------------------------------------- list/extract stage, no takeover
lid_before=$(ph 'pidof lid')
ph 'rm -f /tmp/*.status /tmp/zip-evil-*'

echo "== web panel: multi-ROM zip gives a list (GB/GBC share one launcher)"
r=$(post --data-urlencode "url=$B/multi-gb.zip" "http://$PHONE_IP:8080/cgi-bin/boot-gb")
assert_contains "$r" "several games" "gb: the panel asks which one"
assert_contains "$r" ">a.GB</button>" "gb: .GB listed (case-insensitive)"
assert_contains "$r" ">deep/b.gbc</button>" "gb: .gbc in a subfolder listed"
case "$r" in *c.gba*) fail "gb: a .gba must not be listed" ;; esac; pass "gb: .gba ignored by the GB launcher"
sid=$(printf '%s' "$r" | sed -n 's/.*name="sid" value="\([0-9-]*\)".*/\1/p' | head -n 1)
[ -n "$sid" ] || fail "no session id in the list page"
assert_eq "2" "$(ph 'wc -l < /tmp/zip-gb/list')" "gb: 2 entries stored"
assert_eq "" "$(ph 'ls /tmp/*.zip /tmp/game.gb 2>/dev/null')" "gb: the zip was deleted after unpacking"

echo "== hostile choice parameters (nothing may start or escape)"
for bad in 0 3 99 -1 '1;touch /tmp/pwn' '1%0aid' '../../../etc/passwd' '' '1 2' '$(touch /tmp/pwn)' '`touch /tmp/pwn`' '/tmp/zip-gb/x/a.GB'; do
    r=$(post --data-urlencode "sid=$sid" --data-urlencode "pick=$bad" "http://$PHONE_IP:8080/cgi-bin/boot-gb")
    case "$r" in *"Running on the phone"*|*"Starting"*) fail "hostile pick [$bad] started something" ;; esac
done
pass "12 hostile pick values never start a game"
for badsid in 1 "$sid;id" "$sid x" '../zip-gb/sid' ''; do
    r=$(post --data-urlencode "sid=$badsid" --data-urlencode "pick=1" "http://$PHONE_IP:8080/cgi-bin/boot-gb")
    case "$r" in *"Running on the phone"*) fail "hostile sid [$badsid] started something" ;; esac
done
pass "hostile / stale session ids rejected"
r=$(pw "http://127.0.0.1:8081/cgi-bin/phone-pick?sys=gb&sid=$sid&i=2%3Btouch%20/tmp/pwn")
assert_contains "$r" "not started" "phone-pick: hostile index rejected"
r=$(pw "http://127.0.0.1:8081/cgi-bin/phone-pick?sys=gb&sid=$sid&i=7")
assert_contains "$r" "out of range" "phone-pick: out-of-range index rejected"
r=$(pw "http://127.0.0.1:8081/cgi-bin/phone-pick?sys=..%2F..%2Fx&sid=$sid&i=1")
assert_contains "$r" "Unknown system" "phone-pick: hostile system rejected"
assert_eq "" "$(ph 'ls /tmp/pwn* 2>/dev/null')" "no injected command ran"
assert_eq "$lid_before" "$(ph 'pidof lid')" "phone app untouched"
assert_eq "2" "$(ph 'wc -l < /tmp/zip-gb/list')" "the stored list survives bad picks"

echo "== a new download replaces the stored list"
post --data-urlencode "url=$B/multi-gb.zip" "http://$PHONE_IP:8080/cgi-bin/boot-gb" >/dev/null
sid2=$(ph 'cat /tmp/zip-gb/sid')
[ "$sid" != "$sid2" ] || { sleep 1; post --data-urlencode "url=$B/multi-gb.zip" "http://$PHONE_IP:8080/cgi-bin/boot-gb" >/dev/null; sid2=$(ph 'cat /tmp/zip-gb/sid'); }
[ "$sid" != "$sid2" ] && pass "new session id" || fail "session id not renewed"
r=$(post --data-urlencode "sid=$sid" --data-urlencode "pick=1" "http://$PHONE_IP:8080/cgi-bin/boot-gb")
assert_contains "$r" "stale session" "the old session id is refused"

echo "== zips with no matching file / broken zips fail cleanly"
r=$(post --data-urlencode "url=$B/none.zip" "http://$PHONE_IP:8080/cgi-bin/boot-nes")
assert_contains "$r" "Not started: no .nes file inside the zip" "nes: no match -> clear error"
assert_contains "$(ph 'cat /tmp/nes.log')" "error: no .nes file inside the zip" "nes: error in the launcher log"
r=$(post --data-urlencode "url=$B/gba-none.zip" "http://$PHONE_IP:8080/cgi-bin/boot-gba")
assert_contains "$r" "Not started: no .gba file inside the zip" "gba: a zip with only a .nes fails"
r=$(pw "http://127.0.0.1:8081/cgi-bin/phone-retro?sys=gb&url=$(printf %s "$B/none.zip" | sed 's/:/%3A/g; s|/|%2F|g')")
assert_contains "$r" "no .gb" "gb: error on the phone screen"
r=$(post --data-urlencode "url=$B/fake.nes" "http://$PHONE_IP:8080/cgi-bin/boot-nes")
assert_contains "$r" "Not started" "broken zip: reported, not run"
assert_eq "" "$(ph 'ls -d /tmp/zip-nes /tmp/game.nes 2>/dev/null')" "failed zips leave nothing in /tmp"

echo "== doom: .wad in a zip (two entries -> list), phone menu"
r=$(post --data-urlencode "url=$B/multi-doom.zip" "http://$PHONE_IP:8080/cgi-bin/boot-doom")
assert_contains "$r" ">one.wad</button>" "doom: first wad listed"
assert_contains "$r" ">d/TWO.WAD</button>" "doom: .WAD in a subfolder listed"
r=$(pw "http://127.0.0.1:8081/cgi-bin/phone-games?game=doom")
assert_contains "$r" "phone-pick?sys=doom" "Games menu offers the pending zip choice"
r=$(pw "http://127.0.0.1:8081/cgi-bin/phone-pick?sys=doom")
assert_contains "$r" "<IPPhoneMenu" "phone-pick lists the files"
ph 'rm -rf /tmp/zip-doom /tmp/doom.status'

echo "== a malicious zip cannot write outside its folder"
post --data-urlencode "url=$B/evil.zip" "http://$PHONE_IP:8080/cgi-bin/boot-nes" >/dev/null
assert_eq "" "$(ph 'ls /tmp/zip-evil-* /zip-evil* 2>/dev/null; find /tmp -maxdepth 2 -name "zip-evil*"')" "../ and absolute entry names did not escape"
ph 'rm -rf /tmp/zip-nes /tmp/nes.status'

# ------------------------------------------------------------ real runs (x3)
wait_phone() {
    local i
    for i in $(seq 90); do
        [ "$(ph 'pidof lid >/dev/null && pidof lcsD375 >/dev/null && echo up')" = up ] && { sleep 20; return 0; }
        sleep 5
    done
    return 1
}
quit_game() {  # release first, then press hangup (114)
    ph 'for v in 0 001 0; do printf "\0\0\0\0\0\0\0\0\001\0\162\0\\$v\0\0\0" > /dev/input/event0; usleep 100000; done'
    sleep 3
}
# started_log SYS: wait until the launcher status says running (<= 40 s)
wait_running() { local i; for i in $(seq 40); do [ "$(ph "cat /tmp/$1.status")" = running ] && return 0; sleep 1; done; return 1; }

run1() {  # multi-ROM NES zip: phone list, choice 2
    local r sid
    r=$(pw "http://127.0.0.1:8081/cgi-bin/phone-boot?game=nes&url=$(printf %s "$B/multi-nes.zip" | sed 's/:/%3A/g; s|/|%2F|g')")
    echo "$r" > "$W/r1.xml"
    ph 'cat /tmp/zip-nes/list' > "$W/r1.list"
    sid=$(ph 'cat /tmp/zip-nes/sid')
    echo "$sid" > "$W/r1.sid"
    [ "$(grep -c '<MenuItem' "$W/r1.xml")" = 2 ] || return 1
    # choice 2 is what the list says is number 2
    pw "http://127.0.0.1:8081/cgi-bin/phone-pick?sys=nes&sid=$sid&i=2" > "$W/r1b.xml"
    wait_running nes || return 1
    sleep 6
    ph 'cat /tmp/nes.log' > "$W/r1.log"
    quit_game
}
run2() {  # nested single GB ROM in a zip (web panel)
    post --data-urlencode "url=$B/nested-gb.zip" "http://$PHONE_IP:8080/cgi-bin/boot-gb" > "$W/r2.html"
    wait_running gb || return 1
    sleep 6
    ph 'cat /tmp/gb.log' > "$W/r2.log"
    quit_game
}
run3() {  # plain NES ROM, not a zip
    post --data-urlencode "url=$B/tone.nes" "http://$PHONE_IP:8080/cgi-bin/boot-nes" > "$W/r3.html"
    wait_running nes || return 1
    sleep 6
    ph 'cat /tmp/nes.log' > "$W/r3.log"
    quit_game
}
echo "== real run 1: multi-ROM NES zip, phone list, choice 2"
with_phone_lock run1 || fail "run 1 did not start"
wait_phone || fail "phone app did not come back (1)"
assert_eq "2" "$(grep -c '<MenuItem' "$W/r1.xml")" "phone shows an IPPhoneMenu with 2 entries"
assert_eq "sub/sav.nes
tone.nes" "$(cat "$W/r1.list")" "list: sorted, __MACOSX and ._ files ignored, readme.txt skipped"
# entry 2 of the sorted list is tone.nes
assert_contains "$(cat "$W/r1.log")" "$(sha "$ROMS/tone.nes").srm" "choice 2 ran tone.nes (save key = its hash, same as a plain download)"
assert_contains "$(cat "$W/r1.log")" "chosen entry 2" "launcher log names the choice"
assert_eq "" "$(ph 'ls -d /tmp/zip-nes 2>/dev/null')" "unpacked files removed after the choice"

echo "== real run 2: nested GB ROM in a zip (+ __MACOSX)"
with_phone_lock run2 || fail "run 2 did not start"
wait_phone || fail "phone app did not come back (2)"
assert_contains "$(cat "$W/r2.log")" "$(sha "$ROMS/sav.gb").srm" "nested pack/games/sav.gb ran"

echo "== real run 3: plain non-zip ROM"
with_phone_lock run3 || fail "run 3 did not start"
wait_phone || fail "phone app did not come back (3)"
assert_contains "$(cat "$W/r3.log")" "$(sha "$ROMS/tone.nes").srm" "plain ROM runs unchanged"
case "$(cat "$W/r3.log")" in *unpacking*) fail "plain ROM went through unzip" ;; esac; pass "plain ROM skips the zip path"
echo "ALL PASS"
