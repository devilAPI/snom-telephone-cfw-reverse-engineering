#!/usr/bin/env python3
"""List the D815 files needed on a D375, and write them to a tar file.

    pack.py <d815-rootfs> <out.tar>

The phone has 120 MB of RAM, so this is only what lcsD815 and lid link against,
plus the helpers they call. Flash tools are left out on purpose.
"""
import os
import subprocess
import sys

R, OUT = sys.argv[1:3]
ROOTS = ['snom/lcsD815', 'snom/lid', 'bin/busybox', 'bin/bash', 'bin/fbApp',
         'sbin/ip', 'sbin/dns-proxy', 'usr/bin/ntpdate', 'usr/bin/curl']
TREES = ['etc', 'bin', 'sbin', 'snom/html', 'snom/fonts']
LANG = ['gui_lang_EN.xml', 'web_lang_EN.xml', 'gui_lang_DE.xml', 'web_lang_DE.xml']
FLASH = ('fw_setenv', 'fw_printenv', 'nandwrite', 'nanddump', 'flash_erase',
         'flash_eraseall', 'flashcp', 'swupdate', 'reboot', 'halt', 'poweroff',
         'init')


def needed(path):
    out = subprocess.run(['readelf', '-d', path], capture_output=True, text=True).stdout
    return [x.split('[')[1].split(']')[0] for x in out.splitlines() if 'NEEDED' in x]


def find(name):
    for d in ('lib', 'usr/lib'):
        p = os.path.join(R, d, name)
        if os.path.lexists(p):
            return p
    return None


# Imlib2 opens these with dlopen, so readelf cannot see them. Without them every
# icon fails with "Can't get raw image". They also pull in libjpeg and libgif.
LOADERS = 'usr/lib/imlib2/loaders'
ROOTS = list(ROOTS) + [f'{LOADERS}/{n}' for n in os.listdir(os.path.join(R, LOADERS))]
# glibc opens these the same way. Without them no host name resolves.
ROOTS += ['lib/libnss_dns.so.2', 'lib/libnss_dns-2.19.so',
          'lib/libnss_files.so.2', 'lib/libnss_files-2.19.so']

files = {os.path.join(R, f) for f in ROOTS}
files |= {os.path.join(R, 'lib/ld-linux.so.3'), os.path.join(R, 'lib/ld-2.19.so')}
todo, seen = list(files), set()
while todo:
    for lib in needed(todo.pop()):
        if lib in seen:
            continue
        seen.add(lib)
        p = find(lib)
        if not p:
            sys.exit(f'missing library {lib}')
        files.add(p)
        while os.path.islink(p):
            p = os.path.normpath(os.path.join(os.path.dirname(p), os.readlink(p)))
            files.add(p)
        todo.append(p)

names = {os.path.relpath(f, R) for f in files}
for tree in TREES:
    for base, _, fs in os.walk(os.path.join(R, tree)):
        for n in fs:
            p = os.path.relpath(os.path.join(base, n), R)
            if n in FLASH or n.startswith(('ubi', 'mtd', 'fw_')) or 'zh.ttf' in p:
                continue
            names.add(p)
names |= {'snom/version'} | {f'snom/snomlang/{n}' for n in LANG}
names = sorted(n for n in names if os.path.lexists(os.path.join(R, n)))
subprocess.run(['tar', 'cf', OUT, '-C', R, '--no-recursion', '-T', '-'],
               input='\n'.join(names) + '\n', text=True, check=True)

# Icons the D375 flash lacks. run-d8.sh merges them over the flash tree. The
# Contrast theme is skipped: run-d8.sh selects Dark, and it would cost 9 MB.
D375 = os.path.join(os.path.dirname(__file__), '../../rootfs/d375/snom/bmp')
extra = []
for base, _, fs in os.walk(os.path.join(R, 'snom/bmp/colored')):
    rel = os.path.relpath(base, os.path.join(R, 'snom/bmp'))
    if rel.split('/')[1:2] and rel.split('/')[1] in ('theme_contrast',
                                                     'theme_industrial',
                                                     'theme_colorful'):
        continue
    extra += [f'snom/bmp/{rel}/{n}' for n in fs
              if not os.path.lexists(os.path.join(D375, rel, n))]
subprocess.run(['tar', 'rf', OUT, '-C', R, '--no-recursion',
                '--transform', 's,^snom/bmp/,snom/.bmpx/,', '-T', '-'],
               input='\n'.join(sorted(extra)) + '\n', text=True, check=True)
print(f'{len(extra)} extra icons')
print(f'{OUT}: {len(names)} files, {os.path.getsize(OUT) // 2**20} MB')
