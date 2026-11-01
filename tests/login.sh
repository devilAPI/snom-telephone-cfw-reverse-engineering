#!/bin/bash
# Task H: panel password login (busybox httpd -c /etc/cfw-httpd.conf).
# Restarts the real :8080 httpd WITH auth under the phone lock, runs the checks,
# and always restores the unauthenticated :8080 afterwards (trap), because other
# agents test against :8080 without credentials until the new image is flashed.
. "$(dirname "$0")/lib.sh"

# Restart only the :8080 instance. The logic lives in a script on the phone because
# pkill -f would otherwise match the ssh shell's own command line (which contains the pattern).
restart_8080() {  # [extra httpd args]
    ph_put /dev/stdin /tmp/restart8080.sh <<'SH'
pkill -9 -f 'httpd -p 8080'  # httpd ignores SIGTERM
sleep 1
busybox httpd -p 8080 -h /snom/cfw "$@"
sleep 1
SH
    ph "sh /tmp/restart8080.sh $*"
}
restore() { with_phone_lock restart_8080 >/dev/null; echo "restored unauthenticated :8080"; }
code() { curl -s -o /dev/null -m 20 -w '%{http_code}' "$@"; }

ph_put "$REPO/custom-rootfs/etc/cfw-httpd.conf" /tmp/cfw-httpd.conf   # the shipped file, tested from /tmp
trap restore EXIT
with_phone_lock restart_8080 -c /tmp/cfw-httpd.conf -r "'snom CFW'" >/dev/null

B=http://$PHONE_IP:8080
assert_eq 401 "$(code $B/)"                          "no credentials -> 401"
assert_eq 401 "$(code $B/cgi-bin/reset-pw)"          "CGI without credentials -> 401"
assert_eq 401 "$(code -u root:wrong $B/)"            "wrong password -> 401"
assert_eq 401 "$(code -u admin:snom375 $B/)"         "wrong user -> 401"
assert_eq 200 "$(code -u root:$PHONE_PW $B/)"        "root + SSH password -> 200"
assert_contains "$(curl -s -i -m 10 $B/ | tr -d '\r')" 'WWW-Authenticate: Basic realm="snom CFW"' "realm header"

# Loopback instance: no credentials from the phone, refused from the LAN.
assert_eq 200 "$(ph "wget -S -q -O /dev/null http://127.0.0.1:8081/cgi-bin/phone-tools 2>&1 | grep -c 'HTTP/1.. 200'" | sed 's/^1$/200/')" "8081 on the phone, no creds -> 200"
assert_eq 000 "$(code -m 5 http://$PHONE_IP:8081/cgi-bin/phone-tools)" "8081 unreachable from the LAN"

# Every phone-menu.d entry and the games menu, as the phone's minibrowser fetches them.
n=0
for url in $(ph 'cat /snom/cfw/phone-menu.d/* 2>/dev/null' | cut -d'|' -f2) /cgi-bin/phone-games /cgi-bin/phone-tools; do
    r=$(ph "wget -S -q -O /dev/null 'http://127.0.0.1:8081$url' 2>&1 | grep -c 'HTTP/1.. 200'")
    assert_eq 1 "$r" "8081 $url"; n=$((n+1))
done
echo "checked $n phone URLs"
# state_settings.xml must not point the phone at the authenticated port.
grep -q '127.0.0.1:8080' "$REPO/custom-rootfs/snom/html/xml/gui/state_settings.xml" && fail "state_settings.xml still references :8080"
pass "state_settings.xml has no :8080 reference"

# reset-pw works behind auth (it resets to snom375, the current password, so the login stays valid).
out=$(curl -s -m 30 -u root:$PHONE_PW -X POST $B/cgi-bin/reset-pw)
assert_contains "$out" "reset to the firmware default" "reset-pw with auth"
assert_eq 200 "$(code -u root:$PHONE_PW $B/)" "login still valid after reset-pw"
echo "ALL PASS"
