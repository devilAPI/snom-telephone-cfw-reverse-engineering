#!/usr/bin/env python3
"""Refresh etc/checksum.md5 in a rootfs after files were changed.

Only files already listed are rehashed, and listed files that no longer exist
are dropped. Run under fakeroot so the file keeps its recorded owner.
"""
import hashlib
import os
import sys

root = sys.argv[1] if len(sys.argv) > 1 else 'rootfs/d375'
path = os.path.join(root, 'etc/checksum.md5')
out = []
changed = removed = 0
for line in open(path):
    digest, name = line.rstrip('\n').split(None, 1)
    full = os.path.join(root, name)
    if not os.path.isfile(full):
        removed += 1
        continue
    with open(full, 'rb') as f:
        new = hashlib.md5(f.read()).hexdigest()
    changed += new != digest
    out.append(f'{new}  {name}\n')
with open(path, 'w') as f:
    f.writelines(out)
print(f'checksum.md5: {changed} updated, {removed} removed')
