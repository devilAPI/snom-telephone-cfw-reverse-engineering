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

[ -d "$STAGE/snom/d815" ] || { echo "no stage: run tools/build-custom-firmware.sh"; exit 1; }
exec 9>/tmp/claude-1000/snom-phone.lock 2>/dev/null && flock -n 9 || { echo "phone is locked"; exit 1; }

echo "copying the app to flash"
tar -C "$STAGE/snom/d815" --owner=0 --group=0 -cf - . | p 'mkdir -p /snom/d815; tar xf - -C /snom/d815'
tar -C "$STAGE/snom/bmp" --owner=0 --group=0 -cf - . | p 'tar xf - -C /snom/bmp'
# The CFW scripts that know about the D815 app.
R="$ROOT/custom-rootfs/snom/cfw"
tar -C "$R" -cf - start-d815.sh lib cgi-bin | p 'tar xf - -C /snom/cfw'
p 'cat > /usr/bin/htop && chmod 755 /usr/bin/htop' < "$ROOT/custom-rootfs/usr/bin/htop"
for f in doom/doom nes/infones gba/gpsp gb/gambatte; do
    [ -f "$R/$f" ] && p "cat > /snom/cfw/$f.new && mv /snom/cfw/$f.new /snom/cfw/$f && chmod 755 /snom/cfw/$f" < "$R/$f"
done

# Replaces start.sh for one boot. It restores the original first, with mv because
# the shell is reading this file, so the next boot is normal whatever happens.
# A previous try leaves its start.sh mounted over the real one until reboot, and
# a one-shot written into that mount would vanish. Clear that first.
p 'grep -q " /snom/start.sh " /proc/mounts && umount /snom/start.sh; rm -f /snom/start.sh.orig'
p 'cp -p /snom/start.sh /snom/start.sh.orig
   [ "$(md5sum < /snom/start.sh)" = "$(md5sum < /snom/start.sh.orig)" ] || exit 1
   rm /snom/start.sh; cat > /snom/start.sh; chmod 755 /snom/start.sh; sync' <<'ONESHOT'
#!/bin/sh
mv /snom/start.sh.orig /snom/start.sh
sync
echo 0 > /proc/sys/kernel/printk
# rcS runs start.sh again after a game. This lasts until the next reboot.
printf '#!/bin/sh
exec /snom/cfw/start-d815.sh
' > /tmp/start-try.sh
chmod 755 /tmp/start-try.sh
/snom/cfw/bin/bindmount /tmp/start-try.sh /snom/start.sh
exec /snom/cfw/start-d815.sh
ONESHOT
echo "rebooting the phone"
p 'sync; reboot -f' || true
