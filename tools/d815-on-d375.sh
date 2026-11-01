#!/usr/bin/env bash
# Boot a D375 once into the D815 phone app, from RAM. See docs/backport.md.
#
#   tools/d815-on-d375.sh [phone-ip]
#
# The phone reboots once and stays on the D815 app until the next reboot, which
# returns it to normal. Only /snom/start.sh on flash changes, and only until the
# phone has booted. Your settings are copied into RAM, so the originals stay as
# they are. Needs root SSH to the phone.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOST=${1:-192.168.178.72}
W="$ROOT/emu/backport"; mkdir -p "$W"
SSHOPT=(-q -o ConnectTimeout=6 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
        -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa
        -o KexAlgorithms=+diffie-hellman-group14-sha1)
p() { ssh "${SSHOPT[@]}" "root@$HOST" "$@"; }

[ -f "$ROOT/tools/out/fb24shim.so" ] || "$ROOT/tools/build-fb24shim.sh"
[ -f "$W/d8.tar" ] || python3 "$ROOT/tools/backport/pack.py" \
    "$ROOT/decrypted/D815-10.1.226.16" "$W/d8.tar"

# Network settings the D815 stack needs before lid brings the interface up.
NET=$(p "route -n | awk '\$1==\"0.0.0.0\"{print \$2}'")
exec 9>/tmp/claude-1000/snom-phone.lock 2>/dev/null && flock -n 9 || { echo "phone is locked"; exit 1; }
p "cp -p /snom/start.sh /snom/start.sh.orig
   [ \"\$(md5sum < /snom/start.sh)\" = \"\$(md5sum < /snom/start.sh.orig)\" ] || exit 1
   rm /snom/start.sh; cat > /snom/start.sh; chmod 755 /snom/start.sh; sync" \
    < <(sed "s|^\. /tmp/backport-net.*|ifconfig eth0 $HOST netmask 255.255.255.0 up; route add default gw $NET|" \
        "$ROOT/tools/backport/oneshot.sh")
echo "rebooting the phone"
p 'sync; reboot -f' || true
sleep 25
for _ in $(seq 1 40); do p true 2>/dev/null && break; sleep 3; done
p 'mkdir -p /tmp/d8; mount -t tmpfs -o size=62m tmpfs /tmp/d8; cd /tmp/d8; tar xf -' < "$W/d8.tar"
p 'cat > /tmp/d8/lib/fb24shim.so; chmod 755 /tmp/d8/lib/fb24shim.so' < "$ROOT/tools/out/fb24shim.so"
p 'cat > /tmp/d8/run-d8.sh; touch /tmp/d8/.ready' < "$ROOT/tools/backport/run-d8.sh"
echo "started; the D815 app appears in about a minute"
