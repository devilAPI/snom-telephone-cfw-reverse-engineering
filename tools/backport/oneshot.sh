#!/bin/sh
# Replaces /snom/start.sh for one boot, so the D815 stack starts instead of the
# normal phone. See docs/backport.md.
#
# Restores the original first, so the next boot is normal whatever happens. Use
# mv: the shell reads this file while running it, and overwriting it in place
# makes it carry on with the end of the original, which starts the normal lid.
[ "$(cut -d. -f1 /proc/uptime)" -gt 150 ] && exec sh /snom/start.sh.orig
mv /snom/start.sh.orig /snom/start.sh
sync
echo 0 > /proc/sys/kernel/printk
. /tmp/backport-net 2>/dev/null
i=0
while [ ! -f /tmp/d8/.ready ]; do
    sleep 1; i=$((i+1))
    [ $i -gt 420 ] && exec /snom/start.sh     # nothing uploaded: normal phone
done
exec sh /tmp/d8/run-d8.sh
