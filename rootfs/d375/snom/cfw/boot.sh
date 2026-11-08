#!/bin/sh
# CFW startup. rcS calls this once on every model, so model differences live
# in model.conf and not in rcS.
. /snom/cfw/model.conf

grep -q ' /dev/pts ' /proc/mounts || { mkdir -p /dev/pts; mount devpts /dev/pts -t devpts; }

# OpenSSH 10 needs its privilege separation directory and a modern host key.
mkdir -p /var/empty
[ -e /etc/ssh/ssh_host_ed25519_key ] || \
    /usr/bin/ssh-keygen -q -t ed25519 -N "" -f /etc/ssh/ssh_host_ed25519_key
pidof sshd >/dev/null 2>&1 || /usr/sbin/sshd

# LAN panel: root's system password. Phone's own menus and keys: loopback only,
# with no login, because the minibrowser cannot send credentials.
# The login file stays outside the web root: httpd reads an httpd.conf found there,
# and the loopback server would then ask for a login too.
busybox httpd -p 8080 -h /snom/cfw -c /etc/cfw-httpd.conf -r "snom CFW"
busybox httpd -p 127.0.0.1:8081 -h /snom/cfw

# System log: a 512 KB ring buffer in RAM, read with logread and in the panel's
# Logs tab. start-d815.sh binds its socket into the D815 app's chroot, so the app
# logs there too. Nothing is written to flash.
# boot.sh and start-d815.sh run at the same time: mkdir lets only one start it.
mkdir /tmp/.cfw-syslogd 2>/dev/null && busybox syslogd -C512 -D
