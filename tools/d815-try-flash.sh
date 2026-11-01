#!/usr/bin/env bash
# Try the staged D815 app on a D375 without a firmware update. See
# docs/backport-guide.md.
#
#   tools/d815-try-flash.sh [phone-ip]
#
# Copies emu/backport/stage to /snom/d815 and /snom/bmp, then reboots once into
# it. The boot after that runs the phone's installed firmware again. The copied
# files stay on flash, and the app's settings stay in /snom/snomconfig/d815.
# tools/build-custom-firmware.sh creates the stage. Needs root SSH to the phone.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOST=${1:-192.168.178.72}
STAGE="$ROOT/emu/backport/stage"
SSHOPT=(-q -o ConnectTimeout=6 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
        -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa
        -o KexAlgorithms=+diffie-hellman-group14-sha1)
p() { ssh "${SSHOPT[@]}" "root@$HOST" "$@"; }

[ -d "$STAGE/d815" ] || { echo "no stage: run tools/build-custom-firmware.sh"; exit 1; }
exec 9>/tmp/claude-1000/snom-phone.lock 2>/dev/null && flock -n 9 || { echo "phone is locked"; exit 1; }

echo "copying the app to flash"
tar -C "$STAGE/d815" --owner=0 --group=0 -cf - . | p 'mkdir -p /snom/d815; tar xf - -C /snom/d815'
tar -C "$STAGE/bmp" --owner=0 --group=0 -cf - . | p 'tar xf - -C /snom/bmp'
p 'cat > /snom/cfw/start-d815.sh; chmod 755 /snom/cfw/start-d815.sh' < "$ROOT/cfw/app/start-d815.sh"
p 'cat > /snom/cfw/model.conf' < "$ROOT/cfw/models/d375.conf"

# Replaces start.sh for one boot. It restores the original first, with mv because
# the shell is reading this file, so the next boot is normal whatever happens.
p 'cp -p /snom/start.sh /snom/start.sh.orig
   [ "$(md5sum < /snom/start.sh)" = "$(md5sum < /snom/start.sh.orig)" ] || exit 1
   rm /snom/start.sh; cat > /snom/start.sh; chmod 755 /snom/start.sh; sync' <<'ONESHOT'
#!/bin/sh
mv /snom/start.sh.orig /snom/start.sh
sync
echo 0 > /proc/sys/kernel/printk
exec /snom/cfw/start-d815.sh
ONESHOT
echo "rebooting the phone"
p 'sync; reboot -f' || true
