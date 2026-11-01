#!/bin/bash
# Task K test: persistent saves (docs/saves.md). Needs the phone; the game runs hold the
# phone lock for the whole cycle (screen/audio takeover + phone-restore).
#   boot counter ROMs (tests/roms/sav.{nes,gb,gba}) increment byte 0 of battery RAM per start:
#   NES run1 (hangup) -> 01, run2 (SIGTERM) -> 02, run3 with a blocked save path -> write
#   failure logged, save intact; GB and GBA: run1 -> 01, run2 -> 02 (loaded from flash).
#   The save survives phone-restore (each run is a full takeover + restore).
#   Then the CGI: list, download, delete, hostile names. PHONE REBOOT is not done (the restore
#   restarts lid/media_daemon; /snom/cfw-data is jffs2 flash, see docs/saves.md).
set -u
. "$(dirname "$0")/lib.sh"
C=$REPO/custom-rootfs/snom/cfw
ROMS=$REPO/tests/roms
PORT=${SAVES_PORT:-18766}
trap 'rm -f "$_askpass"' EXIT

deploy() {
    for f in nes/infones gba/gpsp gb/gambatte; do
        ph "rm -f /snom/cfw/$f.new"
        ph_put "$REPO/tools/out/${f#*/}" "/snom/cfw/$f.new"
        ph "mv /snom/cfw/$f.new /snom/cfw/$f"
    done
    for f in lib/saves.sh lib/retro-boot.sh nes/boot-nes.sh doom/boot-doom.sh cgi-bin/saves panel.d/48-saves.html; do
        ph_put "$C/$f" "/snom/cfw/$f"
    done
    ph 'mkdir -p /tmp/sav-roms; netstat -ltn | grep -q "127.0.0.1:'$PORT' " || busybox httpd -p 127.0.0.1:'$PORT' -h /tmp/sav-roms'
    for r in sav.nes sav.gb sav.gba; do ph_put "$ROMS/$r" "/tmp/sav-roms/$r"; done
    ph 'netstat -ltn | grep -q "127.0.0.1:8081 " || busybox httpd -p 127.0.0.1:8081 -h /snom/cfw; true'
}

wait_phone() {
    local i
    for i in $(seq 90); do
        [ "$(ph 'pidof lid >/dev/null && pidof lcsD375 >/dev/null && echo up')" = up ] && { sleep 20; return 0; }
        sleep 5
    done
    return 1
}
hangup() { ph 'for v in 0 001 0; do printf "\0\0\0\0\0\0\0\0\001\0\162\0\\$v\0\0\0" > /dev/input/event0; usleep 100000; done'; }
sha() { ph "sha1sum /tmp/sav-roms/$1" | cut -d' ' -f1; }
b0() { ph "dd if=/snom/cfw-data/saves/$1/$2.srm bs=1 count=1 2>/dev/null" | od -An -tu1 | tr -d ' '; }  # (busybox od has no -t)

# run SYS ROM LOGFILE HOW   (HOW = hangup | term); returns after the phone app is back
run() {
    local sys=$1 rom=$2 log=$3 how=$4
    ph "nohup /snom/cfw/$sys/boot-$sys.sh 'http://127.0.0.1:$PORT/$rom' </dev/null >/dev/null 2>&1 &"
    sleep 20
    if [ "$how" = term ]; then
        ph 'for p in /proc/[0-9]*; do case "$(readlink $p/exe)" in /snom/cfw/*/*) kill -TERM ${p#/proc/};; esac; done'
    else hangup; fi
    wait_phone || fail "$sys: phone app did not come back"
    ph "cat /tmp/$log" > "$TMPD/$sys.log"
}

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"; rm -f "$_askpass"' EXIT

echo "== deploy"
with_phone_lock deploy
nsha=$(sha sav.nes); gsha=$(sha sav.gb); asha=$(sha sav.gba)

cycle() {
    ph "rm -rf /snom/cfw-data/saves/nes /snom/cfw-data/saves/gb /snom/cfw-data/saves/gba"
    echo "== NES"
    run nes sav.nes nes.log hangup
    assert_eq 1 "$(b0 nes "$nsha")" "NES: battery RAM saved on hangup quit (boot counter 1)"
    run nes sav.nes nes.log term
    assert_contains "$(cat "$TMPD/nes.log")" "save: loaded 8192 bytes" "NES: second run loaded the save"
    assert_eq 2 "$(b0 nes "$nsha")" "NES: SIGTERM flushed the save (boot counter 2)"
    ph "mkdir /snom/cfw-data/saves/nes/$nsha.srm.tmp"   # write failure: tmp path is a directory
    run nes sav.nes nes.log hangup
    assert_contains "$(cat "$TMPD/nes.log")" "save: cannot write" "NES: write failure is logged"
    assert_eq 2 "$(b0 nes "$nsha")" "NES: failed write left the old save intact"
    ph "rmdir /snom/cfw-data/saves/nes/$nsha.srm.tmp"
    echo "== GB"
    run gb sav.gb gb.log hangup
    assert_eq 1 "$(b0 gb "$gsha")" "GB: cart RAM saved (boot counter 1)"
    run gb sav.gb gb.log hangup
    assert_contains "$(cat "$TMPD/gb.log")" "save: loaded" "GB: second run loaded the save"
    assert_eq 2 "$(b0 gb "$gsha")" "GB: save loaded and re-saved (boot counter 2)"
    echo "== GBA"
    run gba sav.gba gba.log hangup
    assert_eq 1 "$(b0 gba "$asha")" "GBA: SRAM saved (boot counter 1)"
    run gba sav.gba gba.log hangup
    assert_eq 2 "$(b0 gba "$asha")" "GBA: save loaded and re-saved (boot counter 2)"
}
with_phone_lock cycle || exit 1

echo "== CGI"
page=$(http /cgi-bin/saves)
assert_contains "$page" "nes/$nsha.srm" "saves page lists the NES save"
assert_contains "$(http /cgi-bin/panel)" "<h2>Game saves</h2>" "panel has the saves card"
http "/cgi-bin/saves?act=get&f=nes/$nsha.srm" | head -c 1 | od -An -tu1 | tr -d ' ' > "$TMPD/dl"
assert_eq 2 "$(cat "$TMPD/dl")" "download returns the save"
for bad in '../../etc/passwd' 'nes/../../../etc/passwd' '/etc/passwd' 'nes/.x' 'nes'; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -G --data-urlencode act=get --data-urlencode "f=$bad" "http://$PHONE_IP:8080/cgi-bin/saves")
    assert_eq 404 "$code" "hostile name rejected: $bad"
done
r=$(curl -s -d act=delete --data-urlencode "f=../../etc/passwd" "http://$PHONE_IP:8080/cgi-bin/saves")
assert_contains "$r" "No such save" "hostile delete rejected"
r=$(curl -s -d act=delete --data-urlencode "f=nes/$nsha.srm" "http://$PHONE_IP:8080/cgi-bin/saves")
assert_contains "$r" "Deleted nes/$nsha.srm" "delete removes the save"
assert_eq "" "$(ph "ls /snom/cfw-data/saves/nes/$nsha.srm 2>/dev/null")" "file is gone"
ph "rm -rf /snom/cfw-data/saves/gb /snom/cfw-data/saves/gba /tmp/sav-roms; for p in \$(ps | grep '[h]ttpd -p 127.0.0.1:$PORT' | awk '{print \$1}'); do kill \$p; done"
echo "ALL PASS"
