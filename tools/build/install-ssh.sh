#!/usr/bin/env bash
# Install out/ssh and out/htop into rootfs/d375. Run after
# build-ssh.sh and build-htop.sh. Safe to run again. See docs/ssh-update.md.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
bash -euo pipefail -c '
R=rootfs/d375 O=out
put() { src=$1 dst=$R/$2; if [ -e "$dst" ]; then cat "$src" > "$dst"; else install -m ${3:-755} "$src" "$dst"; fi; }
put $O/ssh/lib/libssl.so.1.1 usr/lib/libssl.so.1.1
put $O/ssh/lib/libcrypto.so.1.1 usr/lib/libcrypto.so.1.1
put $O/ssh/bin/openssl usr/bin/openssl
put $O/ssh/bin/sshd usr/sbin/sshd
for b in ssh scp sftp ssh-keygen ssh-add ssh-agent ssh-keyscan; do put $O/ssh/bin/$b usr/bin/$b; done
put $O/ssh/bin/sftp-server usr/libexec/sftp-server
put $O/ssh/bin/ssh-keysign usr/libexec/ssh-keysign
put $O/ssh/bin/sshd-session usr/libexec/sshd-session
put $O/ssh/bin/sshd-auth usr/libexec/sshd-auth
put $O/htop usr/bin/htop
for f in usr/libexec/sshd-session usr/libexec/sshd-auth usr/bin/htop; do
    grep -qxF "$f" $R/etc/rootfs_files.lst || echo "$f" >> $R/etc/rootfs_files.lst
done
# OpenSSH 10 has no DSA and warns about the old Protocol keyword.
sed -i -e "/^Protocol 2/d" -e "/ssh_host_dsa_key/d" $R/etc/ssh/sshd_config
grep -q ssh_host_ed25519_key $R/etc/ssh/sshd_config || \
    sed -i "/^HostKey .*rsa_key/a HostKey /etc/ssh/ssh_host_ed25519_key" $R/etc/ssh/sshd_config
rm -f $R/etc/ssh/ssh_host_dsa_key $R/etc/ssh/ssh_host_dsa_key.pub
python3 - <<P
p="$R/etc/init.d/rcS"; s=open(p).read()
old="            mount devpts /dev/pts -t devpts\n            /usr/sbin/sshd\n            # CFW Settings"
new="            mount devpts /dev/pts -t devpts\n            # CFW: OpenSSH 10 needs its privsep dir and an ed25519 host key\n            mkdir -p /var/empty\n            [ -e /etc/ssh/ssh_host_ed25519_key ] || /usr/bin/ssh-keygen -q -t ed25519 -N \"\" -f /etc/ssh/ssh_host_ed25519_key\n            /usr/sbin/sshd\n            # CFW Settings"
if "ssh_host_ed25519_key" not in s:
    assert s.count(old)==1
    open(p,"w").write(s.replace(old,new))
P
python3 tools/fw/update-checksums.py $R
'
