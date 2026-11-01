#!/bin/sh
# Starts the D815 stack from the RAM disk on /tmp/d8. See docs/backport.md.

# The D375 voice daemon stays: the D815 one needs different DSP hardware.
cd /snom && (./media_daemon --log -1 --rec 0 --play 0 >/dev/null 2>&1 </dev/null &)

cd /tmp/d8
chmod -R a+rx lib usr bin sbin etc/init.d snom/lcsD815 snom/lid 2>/dev/null
mkdir -p dev/input dev/pts proc sys tmp/var/run var/run var/log var/lock run snom/bmp snom/snomconfig
for n in null zero random urandom tty console ptmx fb0 fb1 snomled; do
    [ -e /dev/$n ] && cp -a /dev/$n dev/
done
cp -a /dev/input/event0 dev/input/
# No /dev/mtd* on purpose: nothing in here may reach the phone's flash.

printf '#!/bin/sh\nwhile :; do sleep 3600; done\n' > snom/media_daemon
chmod 755 snom/media_daemon
echo /lib/fb24shim.so > etc/ld.so.preload
cp /etc/resolv.conf /etc/passwd /etc/group /etc/hosts etc/ 2>/dev/null

# The phone's settings, as a copy: the newer app must not rewrite the real ones.
cp -a /snom/snomconfig/. snom/snomconfig/

# Without web credentials the app stops at its setup wizard.
# Provisioning stays off: this URL serves D375 settings and firmware.
sed -i '/^<setting_server/d' snom/snomconfig/config.xml
sed -i '/^<phone-settings/a\
<smartlabel_idle_default perm="" c="1" trusted="true">off</smartlabel_idle_default>\
<smartlabel_call_default perm="" c="1" trusted="true">off</smartlabel_call_default>\
<http_user perm="" c="1" trusted="true">admin</http_user>\
<http_pass perm="" c="1" trusted="true">snom375</http_pass>\
<admin_mode_password perm="" c="1" trusted="true">snom375</admin_mode_password>\
<admin_mode_password_confirm perm="" c="1" trusted="true">snom375</admin_mode_password_confirm>' snom/snomconfig/config.xml

# Stand-ins for the D815's switch attributes, see redirect() in fb24shim.c.
mkdir -p tmp/gsw120
echo 0 > tmp/gsw120/pc_port_link_status
echo auto > tmp/gsw120/net_port_speed_mode
echo auto > tmp/gsw120/pc_port_speed_mode
echo 0 > tmp/gsw120/net_port_ieee8023az_enable
echo 0 > tmp/gsw120/pc_port_ieee8023az_enable

# Stand-in for the D815's backlight, see sync_backlight() in fb24shim.c.
echo 64 > tmp/backlight
chmod 666 tmp/backlight

# The Settings key has no D815 code, so fb24shim.c runs this.
cat > bin/phone-key <<'EOF'
#!/bin/sh
C=/snom/snomconfig/config.xml
export PATH=/bin:/usr/bin LD_LIBRARY_PATH=/lib:/usr/lib
U=$(sed -n 's/^<http_user[^>]*>\([^<]*\)<.*/\1/p' $C)
P=$(sed -n 's/^<http_pass[^>]*>\([^<]*\)<.*/\1/p' $C)
exec curl -s -f --anyauth -u "$U:$P" -o /dev/null "http://127.0.0.1/command.htm?key=$1"
EOF
chmod 755 bin/phone-key

mount -t proc proc proc
mount -t sysfs sys sys
mount --bind /dev/pts dev/pts
# Icons from flash, which uses no RAM. snom/bmp/colored is a RAM folder with one
# plain bind mount per folder: the app does not follow symlinked folders, and
# nested rbinds came up empty on kernel 2.6.27. The app's default theme, Contrast,
# is missing from the D375 flash, so it gets the Dark icons.
B=snom/.bmp0/colored
C=snom/bmp/colored
mkdir -p snom/.bmp0 "$C"
mount --bind /snom/bmp snom/.bmp0
for f in "$B"/*; do
    n=${f##*/}
    [ "$n" = theme_dark ] && continue
    if [ -d "$f" ]; then
        mkdir "$C/$n"
        mount --bind "$f" "$C/$n"
    else
        ln -s "/$f" "$C/"
    fi
done
for f in "$B"/theme_dark/*; do
    n=${f##*/}
    for t in theme_dark theme_contrast; do
        if [ -d "$f" ]; then
            mkdir -p "$C/$t/$n"
            mount --bind "$f" "$C/$t/$n"
        else
            ln -s "/$f" "$C/$t/"
        fi
    done
done

# Folders with D815-only icons: those icons plus symlinks to the flash ones.
for d in $(cd snom/.bmpx && find colored -type f | sed 's|/[^/]*$||' | sort -u); do
    for f in snom/.bmp0/$d/*; do
        n=${f##*/}
        [ -e "$f" ] && [ ! -e "snom/.bmpx/$d/$n" ] && ln -s "/snom/.bmp0/$d/$n" "snom/.bmpx/$d/"
    done
    for t in "$d" "$(echo "$d" | sed 's|^colored/theme_dark/|colored/theme_contrast/|')"; do
        mkdir -p "snom/bmp/$t"
        mount --bind "snom/.bmpx/$d" "snom/bmp/$t"
    done
done

cd /
exec chroot /tmp/d8 /bin/sh -c 'export PATH=/sbin:/bin:/usr/sbin:/usr/bin LD_LIBRARY_PATH=/lib:/usr/lib FREETYPE_PROPERTIES=truetype:interpreter-version=35; cd /snom && exec ./lid' > /tmp/lid815.log 2>&1
