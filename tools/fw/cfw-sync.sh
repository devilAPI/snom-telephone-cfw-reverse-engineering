#!/usr/bin/env bash
# Install the CFW panel and boot hook into the D815 rootfs tree.
#   tools/fw/cfw-sync.sh <rootfs-dir>
# The D375 tree is the reference: CGIs that work unchanged on the D815 are copied
# from rootfs/d375/snom/cfw; src/cfw-d815/ holds the D815's own versions.
# Games stay in the rootfs tree for now; see docs/multi-model.md.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
R=$1 C=$1/snom/cfw D375=$ROOT/rootfs/d375/snom/cfw OWN=$ROOT/src/cfw-d815
mkdir -p "$C/cgi-bin" "$C/defaults" "$C/local/cgi-bin"
for f in backup doom-log index.cgi key phone-url reboot reset-pw reset-ssh screenshot; do
    cp "$D375/cgi-bin/$f" "$C/cgi-bin/"
done
cp "$OWN"/cgi-bin/* "$C/cgi-bin/"
cp "$OWN"/{boot.sh,httpd.conf,model.conf} "$C/"
cp "$D375/defaults/sshd_config" "$C/defaults/"
chmod 755 "$C"/cgi-bin/* "$C/boot.sh"
for f in phone-games phone-url phone-boot; do
    ln -sf "/snom/cfw/cgi-bin/$f" "$C/local/cgi-bin/$f"
done
# The login page of busybox httpd needs an index for the root URL.
printf '<meta http-equiv="refresh" content="0; url=/cgi-bin/index.cgi">\n' > "$C/index.html"
cp "$D375/defaults/sshd_config" "$R/etc/ssh/sshd_config"
sed -i 's#127\.0\.0\.1:8080#127.0.0.1:8081#g' "$R/snom/html/xml/gui/state_settings.xml"

python3 - "$R/etc/init.d/rcS" <<'P'
import re, sys
p = sys.argv[1]
s = open(p).read()
hook = '/snom/cfw/boot.sh'
if hook not in s:
    # One hook just before the start mode decides what runs next.
    old = '    getStartMode\n    case $? in\n'
    assert s.count(old) == 1
    s = s.replace(old, f'    {hook}   # CFW\n\n{old}')
# Inline startup from before the hook existed.
s = re.sub(r'( +mkdir -p /dev/pts\n +mount devpts /dev/pts -t devpts\n)?'
           r' +# CFW: OpenSSH 10 needs.*?\n +mkdir -p /var/empty\n.*?ssh_host_ed25519_key\n'
           r' +/usr/sbin/sshd\n +# CFW Settings.*?\n +busybox httpd -p 8080[^\n]*\n',
           '', s, flags=re.S)
open(p, 'w').write(s)
P
# Update images land in /tmp. 40 MB is close to the image size, and the phone has
# RAM to spare. This takes effect once a build containing it has been installed.
sed -i 's/remount,size=40M/remount,size=64M/' "$R/etc/init.d/rcS"
python3 "$ROOT/tools/fw/update-checksums.py" "$R"
