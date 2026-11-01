#!/usr/bin/env python3
"""Lay out the D815 phone app for the D375 CFW image.

    stage.py <d8.tar> <fb24shim.so> <d375-rootfs> <out-dir>

Writes <out>/d815, installed as /snom/d815, and <out>/bmp, added to /snom/bmp.
See docs/backport-guide.md.
"""
import os
import re
import shutil
import stat
import subprocess
import sys

TAR, SHIM, D375, OUT = sys.argv[1:5]
APP = os.path.join(OUT, 'd815')
BMP = os.path.join(OUT, 'bmp')

GAMES_RE = re.compile(r'  <!-- CFW: Doom / NES launcher.*?</Menu>\n', re.S)
INFO = '  <Menu name="$(lang:information_settings)" id="information">'

PHONE_KEY = """#!/bin/sh
# Press a phone key through command.htm: phone-key NAME. It reads the login each
# time, because the web password can be changed in the app.
C=/snom/snomconfig/config.xml
export PATH=/bin:/usr/bin LD_LIBRARY_PATH=/lib:/usr/lib
U=$(sed -n 's/^<http_user[^>]*>\\([^<]*\\)<.*/\\1/p' $C)
P=$(sed -n 's/^<http_pass[^>]*>\\([^<]*\\)<.*/\\1/p' $C)
exec curl -s -f --anyauth -u "$U:$P" -o /dev/null "http://127.0.0.1/command.htm?key=$1"
"""

# The D375's own voice daemon runs outside the chroot.
MEDIA_STUB = '#!/bin/sh\nwhile :; do sleep 3600; done\n'


def write(path, text, mode=0o644):
    with open(path, 'w') as f:
        f.write(text)
    os.chmod(path, mode)


shutil.rmtree(OUT, ignore_errors=True)
os.makedirs(APP)
subprocess.run(['tar', 'xf', TAR, '-C', APP], check=True)

# D815-only icons go into the phone's own icon tree.
extra = os.path.join(APP, 'snom/.bmpx')
if os.path.isdir(extra):
    shutil.move(extra, BMP)
else:
    os.makedirs(os.path.join(BMP, 'colored'))

# Contrast is the app's default theme and the D375 has none, so it uses the Dark
# icons. Folders must be real: the app does not follow symlinked folders.
dark = {}
for top in (os.path.join(D375, 'snom/bmp/colored/theme_dark'),
            os.path.join(BMP, 'colored/theme_dark')):
    for base, _, files in os.walk(top):
        rel = os.path.relpath(base, top)
        dark.setdefault(rel, set()).update(files)
for rel, files in dark.items():
    d = os.path.normpath(os.path.join(BMP, 'colored/theme_contrast', rel))
    os.makedirs(d, exist_ok=True)
    up = os.path.relpath(os.path.join(BMP, 'colored/theme_dark', rel), d)
    for n in files:
        os.symlink(os.path.join(up, n), os.path.join(d, n))

for d in ('dev', 'proc', 'sys', 'tmp', 'var', 'run', 'snom/bmp', 'snom/snomconfig'):
    os.makedirs(os.path.join(APP, d), exist_ok=True)
for d in ('lib', 'usr', 'bin', 'sbin', 'etc/init.d'):
    for base, dirs, files in os.walk(os.path.join(APP, d)):
        for n in dirs + files:
            p = os.path.join(base, n)
            if not os.path.islink(p):
                os.chmod(p, os.stat(p).st_mode | 0o555)
for n in ('snom/lcsD815', 'snom/lid'):
    os.chmod(os.path.join(APP, n), 0o755)

shutil.copy(SHIM, os.path.join(APP, 'lib/fb24shim.so'))
os.chmod(os.path.join(APP, 'lib/fb24shim.so'), 0o755)
write(os.path.join(APP, 'etc/ld.so.preload'), '/lib/fb24shim.so\n')
write(os.path.join(APP, 'bin/phone-key'), PHONE_KEY, 0o755)
write(os.path.join(APP, 'snom/media_daemon'), MEDIA_STUB, 0o755)
for n in ('passwd', 'group', 'hosts'):
    if os.path.exists(os.path.join(D375, 'etc', n)):
        shutil.copy(os.path.join(D375, 'etc', n), os.path.join(APP, 'etc', n))
# lid rewrites this at every boot, so it stays off the flash.
p = os.path.join(APP, 'etc/resolv.conf')
if os.path.lexists(p):
    os.remove(p)
os.symlink('/tmp/resolv.conf', p)

# The Games menu of the D375 CFW.
ours = open(os.path.join(D375, 'snom/html/xml/gui/state_settings.xml')).read()
theirs = os.path.join(APP, 'snom/html/xml/gui/state_settings.xml')
s = open(theirs).read()
if s.count(INFO) != 1 or not GAMES_RE.search(ours):
    sys.exit('state_settings.xml layout changed; cannot add the Games menu')
write(theirs, s.replace(INFO, GAMES_RE.search(ours).group() + INFO))
print(f'{OUT}: staged')
