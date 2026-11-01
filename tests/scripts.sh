#!/bin/bash
# Task A test: Scripts menu. Run from repo root. Needs tests/lib.sh (Task 0).
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
R=custom-rootfs/snom/cfw
L() { ph "curl -s 'http://127.0.0.1:8081$1'"; }
deploy() {
  local f
  for f in lib/scripts-run.sh cgi-bin/phone-scripts cgi-bin/scripts panel.d/60-scripts.html phone-menu.d/10-scripts \
           scripts-examples/wake-on-lan.sh scripts-examples/http-get.sh; do
    ph_put "$R/$f" "/snom/cfw/$f"
  done
  ph 'chmod 755 /snom/cfw/cgi-bin/phone-scripts /snom/cfw/cgi-bin/scripts; mkdir -p /snom/cfw-data/scripts
      echo "echo hello-out; echo to-err >&2" > /snom/cfw-data/scripts/t-echo.sh
      printf "echo begin\nsleep 25\necho never\n" > /snom/cfw-data/scripts/t-slow.sh'
}
with_phone_lock deploy || fail "deploy"
assert_contains "$(L /cgi-bin/phone-scripts)" "t-echo.sh" "list"
assert_contains "$(L /cgi-bin/phone-scripts)" "<IPPhoneMenu" "menu xml"
O=$(L '/cgi-bin/phone-scripts?run=t-echo.sh')
assert_contains "$O" "hello-out" "output"; assert_contains "$O" "to-err" "output"
T0=$(date +%s); O=$(L '/cgi-bin/phone-scripts?run=t-slow.sh'); T1=$(date +%s)
assert_contains "$O" "timeout" "output"; assert_contains "$O" "begin" "output"
[ $((T1-T0)) -le 32 ] || fail "slow script not killed at 20s"
[ -z "$(ph 'ps | grep "sleep 25" | grep -v grep')" ] || fail "child survived"
for n in '..%2Fx.sh' 'a%3Bb.sh' '%24(id).sh' 'a%20b.sh'; do
  assert_contains "$(L "/cgi-bin/phone-scripts?run=$n")" "Invalid script name"
done
assert_contains "$(http /cgi-bin/scripts)" "t-echo.sh" "list"
U="http://$PHONE_IP:8080/cgi-bin/scripts"
assert_contains "$(curl -s -m 20 -d 'act=save&name=t-web.sh&content=echo+web-ok%0Aecho+%24%28id%29' $U)" "Saved t-web.sh" "panel save"
assert_contains "$(ph 'cat /snom/cfw-data/scripts/t-web.sh')" '$(id)' "content kept literal"
assert_contains "$(curl -s -m 30 -d 'act=run&name=t-web.sh' $U)" "web-ok" "panel run"
assert_contains "$(curl -s -m 20 -d 'act=save&name=..%2Fx.sh&content=x' $U)" "Invalid name" "panel hostile name"
assert_contains "$(curl -s -m 20 -d 'act=delete&name=t-web.sh' $U)" "Deleted t-web.sh" "panel delete"
ph 'rm -f /snom/cfw-data/scripts/t-echo.sh /snom/cfw-data/scripts/t-slow.sh'
pass "all scripts tests"
