#!/bin/sh
# Starts the D815 phone app from /snom/d815. start.sh runs this in place of lid.
# See docs/backport-guide.md.
R=/snom/d815
CFG=/snom/snomconfig/d815

# The D375 voice daemon stays: the D815 one needs different DSP hardware.
cd /snom && (./media_daemon --log -1 --rec 0 --play 0 >/dev/null 2>&1 </dev/null &)

cd "$R" || exit 1
for d in dev tmp var run; do
    mount -t tmpfs -o size=8m tmpfs "$d"
done
mkdir -p dev/input dev/pts tmp/var/run var/run var/log var/lock tmp/gsw120
for n in null zero random urandom tty console ptmx fb0 fb1 snomled; do
    [ -e "/dev/$n" ] && cp -a "/dev/$n" dev/
done
cp -a /dev/input/event0 dev/input/
# No /dev/mtd* on purpose: nothing in here should reach the flash directly.

# Stand-ins for D815 hardware, see redirect() in fb24shim.c.
echo 0 > tmp/gsw120/pc_port_link_status
echo auto > tmp/gsw120/net_port_speed_mode
echo auto > tmp/gsw120/pc_port_speed_mode
echo 0 > tmp/gsw120/net_port_ieee8023az_enable
echo 0 > tmp/gsw120/pc_port_ieee8023az_enable
mkdir -p tmp/gpio
# The D375's two status LEDs: stay lit from boot unless something turns them off.
for g in 32 18; do
    [ -d "/sys/class/gpio/gpio$g" ] || echo "$g" > /sys/class/gpio/export
    echo out > "/sys/class/gpio/gpio$g/direction"
    echo 0 > "/sys/class/gpio/gpio$g/value"
done
echo 64 > tmp/backlight
chmod 666 tmp/backlight

# The app gets its own settings, so the D375 app's stay as they were. The first
# boot copies them. Web credentials are needed or the app stops at its setup
# wizard. setting_server is dropped because that URL serves D375 firmware. The
# side panels show short labels, five per side: the app cannot do six.
if [ ! -f "$CFG/config.xml" ]; then
    mkdir -p "$CFG"
    for f in /snom/snomconfig/*; do
        [ "$f" = "$CFG" ] || cp -a "$f" "$CFG/"
    done
    [ -f "$CFG/config.xml" ] || \
        printf '<?xml version="1.0" encoding="utf-8"?>\n<phone-settings e="2">\n</phone-settings>\n' > "$CFG/config.xml"
    CFW_DEFAULT_PW=snom375
    sed -i '/^<setting_server/d' "$CFG/config.xml"
    sed -i "/^<phone-settings/a\\
<smartlabel_idle_default perm=\"\" c=\"1\" trusted=\"true\">short</smartlabel_idle_default>\\
<smartlabel_call_default perm=\"\" c=\"1\" trusted=\"true\">short</smartlabel_call_default>\\
<http_user perm=\"\" c=\"1\" trusted=\"true\">admin</http_user>\\
<http_pass perm=\"\" c=\"1\" trusted=\"true\">$CFW_DEFAULT_PW</http_pass>\\
<admin_mode_password perm=\"\" c=\"1\" trusted=\"true\">$CFW_DEFAULT_PW</admin_mode_password>\\
<admin_mode_password_confirm perm=\"\" c=\"1\" trusted=\"true\">$CFW_DEFAULT_PW</admin_mode_password_confirm>" "$CFG/config.xml"
    # A name too wide for the identity tile scrolls, and every step redraws it as a
    # PNG, which took a quarter of the CPU. Show the short user name instead.
    NAME=$(sed -n 's/^<user_name idx="1"[^>]*>\([^<]*\)<.*/\1/p' "$CFG/config.xml" | tr -d '\r')
    [ -z "$NAME" ] || sed -i "/^<phone-settings/a\\
<user_idle_text idx=\"1\" perm=\"\" c=\"1\" trusted=\"true\">$NAME</user_idle_text>" "$CFG/config.xml"
    sync
fi

mount --bind "$CFG" snom/snomconfig
mount --bind /snom/bmp snom/bmp
mount -t proc proc proc
mount -t sysfs sys sys
mount --bind /dev/pts dev/pts
# The app's syslog() goes to boot.sh's ring buffer: bind its socket into the chroot.
# busybox mount refuses to bind a socket, so bindmount does it.
mkdir /tmp/.cfw-syslogd 2>/dev/null && busybox syslogd -C512 -D
for i in 1 2 3 4 5; do [ -S /var/log/.log ] && break; sleep 1; done
[ -S /var/log/.log ] && : > dev/log && /snom/cfw/bin/bindmount /var/log/.log dev/log

cd /
exec chroot "$R" /bin/sh -c 'export PATH=/sbin:/bin:/usr/sbin:/usr/bin LD_LIBRARY_PATH=/lib:/usr/lib FREETYPE_PROPERTIES=truetype:interpreter-version=35; cd /snom && exec ./lid' > "$R/tmp/lid.log" 2>&1
