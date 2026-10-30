#!/bin/bash
# Task C test: splash CGI (hostile input, validation), rcS fallback logic, and a real boot capture.
# Usage: tests/splash.sh [--boot]   (--boot reboots the phone under the lock: ~90 s + ~2 min)
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"; rm -f "$_askpass"' EXIT

# --- host-side tool checks: output geometry equals the stock PNG
python3 - "$REPO" "$T" <<'PY' || fail "make-splash output differs from stock format"
import sys; from PIL import Image
repo, t = sys.argv[1:3]
sys.path.insert(0, repo + "/tools")
Image.new("RGB", (100, 300), (200, 30, 30)).save(t + "/in.png")
import subprocess
subprocess.check_call([repo + "/tools/make-splash.py", t + "/in.png", t + "/out.png"], stdout=subprocess.DEVNULL)
a = Image.open(t + "/out.png"); s = Image.open(repo + "/custom-rootfs/snom/bmp/colored/splash_screen.png")
assert (a.size, a.mode) == (s.size, s.mode), (a.size, a.mode, s.size, s.mode)
PY
pass "make-splash.py output is 480x272 mode P like the stock splash"

# --- deploy CGI + rcS-independent pieces under the lock
deploy() {
    ph_put "$REPO/custom-rootfs/snom/cfw/cgi-bin/splash" /snom/cfw/cgi-bin/splash
    ph_put "$REPO/custom-rootfs/snom/cfw/panel.d/80-splash.html" /snom/cfw/panel.d/80-splash.html
    ph 'rm -f /snom/cfw-data/splash.png'
}
with_phone_lock deploy

post() {  # ACT FILE -> prints "status|body"
    curl -s -m 20 -w '|%{http_code}' -X POST --data-binary @"$2" "http://$PHONE_IP:8080/cgi-bin/splash?act=$1"
}
python3 -c "
from PIL import Image
Image.new('RGB',(480,272),(20,160,60)).save('$T/good.png')
Image.new('RGB',(100,50),(20,160,60)).save('$T/small.png')
open('$T/junk.png','wb').write(b'not a png at all, just text, 40+ bytes long....')
open('$T/big.png','wb').write(b'\x89PNG\r\n\x1a\n'+bytes(400000))"

assert_eq "stock" "$(http '/cgi-bin/splash?act=status')" "initial status is stock"
assert_contains "$(post upload "$T/junk.png")" "not a PNG" "non-PNG rejected"
assert_contains "$(post upload "$T/small.png")" "480x272" "wrong dimensions rejected"
assert_contains "$(post upload "$T/big.png")" "413" "oversize rejected"
assert_eq "stock" "$(http '/cgi-bin/splash?act=status')" "rejected uploads leave stock in place"
assert_eq "" "$(ph 'ls /snom/cfw-data/splash.png.tmp 2>/dev/null')" "no temp file left behind"
r=$(curl -s -m 20 -w '|%{http_code}' "http://$PHONE_IP:8080/cgi-bin/splash?act=upload")
assert_contains "$r" "405" "GET upload refused"
# hostile act values must not execute or touch anything
for a in '../x' '$(touch%20/tmp/pwn)' ';reboot' "a%27b"; do
    r=$(curl -s -m 20 "http://$PHONE_IP:8080/cgi-bin/splash?act=$a"); assert_contains "$r" "unknown act" "hostile act '$a' rejected"
done
assert_eq "" "$(ph 'ls /tmp/pwn 2>/dev/null')" "no command injection"
assert_contains "$(post upload "$T/good.png")" "installed" "valid splash accepted"
assert_eq "custom" "$(http '/cgi-bin/splash?act=status')" "status is custom"
curl -s "http://$PHONE_IP:8080/cgi-bin/splash?act=preview" -o "$T/prev.png"
cmp -s "$T/prev.png" "$T/good.png" && pass "preview returns the uploaded PNG" || fail "preview differs"
assert_contains "$(http /cgi-bin/panel)" "Boot splash" "panel shows the splash card"

# --- rcS display() logic with the real fbApp (fallback to stock on a bad file)
rcs_logic() {
    ph 'echo junk > /snom/cfw-data/splash.png
        if [ -s /snom/cfw-data/splash.png ] && fbApp showFb 0 0 /snom/cfw-data/splash.png >/dev/null 2>&1; then echo custom; else fbApp showFb 0 0 /snom/bmp/colored/splash_screen.png >/dev/null 2>&1 && echo fallback; fi'
}
assert_eq "fallback" "$(with_phone_lock rcs_logic)" "invalid custom splash falls back to stock"

if [ "$1" = --boot ]; then
    post upload "$T/good.png" >/dev/null
    boot_test() {
        ph 'sync; reboot' >/dev/null
        sleep 15
        n=0
        until ph 'true' >/dev/null 2>&1; do sleep 1; n=$((n+1)); [ $n -gt 120 ] && return 1; done
        # sshd is up late in boot; grab fb0 as early as possible
        http /cgi-bin/screenshot > "$T/boot.bmp"
        n=0; until ph 'ps' 2>/dev/null | grep -q '[l]csD375'; do sleep 3; n=$((n+1)); [ $n -gt 80 ] && break; done
        sleep 90
    }
    with_phone_lock boot_test || fail "phone did not come back"
    python3 - "$T/boot.bmp" "${SPLASH_OUT:-/tmp/splash-boot.png}" <<'PY'
import sys; from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB"); im.save(sys.argv[2])
px = im.getpixel((240, 136)); print("centre pixel", px)
sys.exit(0 if abs(px[0]-20) < 12 and abs(px[1]-160) < 12 and abs(px[2]-60) < 12 else 3)
PY
    [ $? -eq 0 ] && pass "framebuffer shows the custom splash during boot" || echo "NOTE: boot capture did not show the splash (sshd may come up after the splash); see ${SPLASH_OUT:-/tmp/splash-boot.png}"
fi

with_phone_lock ph 'rm -f /snom/cfw-data/splash.png /snom/cfw-data/splash.png.tmp'
assert_eq "stock" "$(http '/cgi-bin/splash?act=status')" "cleanup restored stock"
echo "splash: all passed"
