#!/bin/bash
# Task A test: Scripts menu. Run from repo root. Needs tests/lib.sh (Task 0).
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
R=custom-rootfs/snom/cfw
L() { ph "curl -s 'http://127.0.0.1:8081$1'"; }
with_phone_lock bash -c '. tests/lib.sh
  for f in lib/scripts-run.sh cgi-bin/phone-scripts cgi-bin/scripts panel.d/60-scripts.html phone-menu.d/10-scripts; do
    ph "mkdir -p /snom/cfw/$(dirname $f)"; ph_put '"$R"'/$f /snom/cfw/$f; done
  ph "chmod 755 /snom/cfw/cgi-bin/phone-scripts /snom/cfw/cgi-bin/scripts; mkdir -p /snom/cfw-data/scripts; echo \"echo hello-out; echo to-err >&2\" > /snom/cfw-data/scripts/t-echo.sh; printf \"echo begin\nsleep 25\necho never\n\" > /snom/cfw-data/scripts/t-slow.sh"' || fail "deploy"
assert_contains "$(L /cgi-bin/phone-scripts)" "t-echo.sh"
assert_contains "$(L /cgi-bin/phone-scripts)" "<IPPhoneMenu"
O=$(L '/cgi-bin/phone-scripts?run=t-echo.sh')
assert_contains "$O" "hello-out"; assert_contains "$O" "to-err"
T0=$(date +%s); O=$(L '/cgi-bin/phone-scripts?run=t-slow.sh'); T1=$(date +%s)
assert_contains "$O" "timeout"; assert_contains "$O" "begin"
[ $((T1-T0)) -le 24 ] || fail "slow script not killed at 20s"
[ -z "$(ph 'ps | grep "sleep 25" | grep -v grep')" ] || fail "child survived"
for n in '..%2Fx.sh' 'a%3Bb.sh' '%24(id).sh' 'a%20b.sh'; do
  assert_contains "$(L "/cgi-bin/phone-scripts?run=$n")" "Invalid script name"
done
assert_contains "$(http /cgi-bin/scripts)" "t-echo.sh"
ph 'rm -f /snom/cfw-data/scripts/t-echo.sh /snom/cfw-data/scripts/t-slow.sh'
pass
