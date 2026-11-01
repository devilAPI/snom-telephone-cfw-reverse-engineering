#!/usr/bin/env bash
# Install the shared CFW from cfw/ into a model's rootfs tree.
#   tools/cfw-sync.sh <d375|d815> <rootfs-dir>
# Games stay in the rootfs tree for now; only the panel and hook are shared.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MODEL=$1 R=$2
C="$R/snom/cfw"
mkdir -p "$C/cgi-bin" "$C/defaults" "$C/local/cgi-bin"
cp "$ROOT"/cfw/panel/cgi-bin/* "$C/cgi-bin/"
cp "$ROOT"/cfw/panel/{boot.sh,httpd.conf} "$C/"
cp "$ROOT"/cfw/panel/defaults/sshd_config "$C/defaults/"
cp "$ROOT/cfw/models/$MODEL.conf" "$C/model.conf"
chmod 755 "$C"/cgi-bin/* "$C/boot.sh"
rm -f "$C/index.html"
for f in phone-games phone-url phone-boot; do
    [ -f "$C/cgi-bin/$f" ] && ln -sf "/snom/cfw/cgi-bin/$f" "$C/local/cgi-bin/$f"
done
# The login page of busybox httpd needs an index for the root URL.
printf '<meta http-equiv="refresh" content="0; url=/cgi-bin/index.cgi">\n' > "$C/index.html"
cp "$ROOT/cfw/panel/defaults/sshd_config" "$R/etc/ssh/sshd_config"
if [ "$MODEL" = d375 ]; then
    # The D375 runs the D815 phone app. Creating /snom/cfw-data/use-d375-app
    # brings the original app back.
    cp "$ROOT/cfw/app/start-d815.sh" "$C/"
    chmod 755 "$C/start-d815.sh"
    grep -q start-d815 "$R/snom/start.sh" || sed -i \
        's|^exec \./lid$|[ -f /snom/cfw-data/use-d375-app ] \|\| exec /snom/cfw/start-d815.sh\nexec ./lid|' \
        "$R/snom/start.sh"
fi
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
python3 "$ROOT/tools/update-checksums.py" "$R"
