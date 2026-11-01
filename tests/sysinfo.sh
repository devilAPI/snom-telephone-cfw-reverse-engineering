#!/bin/bash
# Task I test: deploys the sysinfo CGIs to the phone and checks them.
. "$(dirname "$0")/lib.sh"
C=$REPO/custom-rootfs/snom/cfw
deploy() {
    ph_put $C/cgi-bin/sysinfo /snom/cfw/cgi-bin/sysinfo
    ph_put $C/cgi-bin/sysinfo.json /snom/cfw/cgi-bin/sysinfo.json
    ph_put $C/lib/cfw.sh /snom/cfw/lib/cfw.sh
    ph "echo '<script>alert(1)</script> & \"q\"' > /tmp/sysinfo-test.log"
}
with_phone_lock deploy

J=$(http /cgi-bin/sysinfo.json)
echo "$J" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for k in ("uptime_s","load","cpu","mem","fs","mtd","procs"): assert k in d,k
for k in ("root","tmp","protected"): assert d["fs"][k]["size_kb"]>0,k
assert abs(d["mem"]["total_kb"]-122720)<=12272, d["mem"]
assert 0<d["mem"]["free_kb"]<=d["mem"]["total_kb"]
assert d["uptime_s"]>0 and len(d["mtd"])>=5 and 1<=len(d["procs"])<=10
' && pass "JSON keys and numbers plausible" || fail "JSON check"

H=$(http /cgi-bin/sysinfo)
assert_contains "$H" "MemTotal" "html has meminfo"
assert_contains "$H" "/protected" "html has df of /protected"
assert_contains "$H" "&lt;script&gt;alert(1)&lt;/script&gt;" "log line escaped"
case "$H" in *"<script>alert"*) fail "raw <script> leaked" ;; *) pass "no raw <script>" ;; esac
ph "rm -f /tmp/sysinfo-test.log"
exit 0
