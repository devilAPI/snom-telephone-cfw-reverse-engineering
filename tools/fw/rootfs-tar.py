#!/usr/bin/env python3
"""Build a firmware rootfs tarball, or create the metadata manifest it needs.

    rootfs-tar.py manifest <rootfs.tar.gz> <rootfs.manifest>
    rootfs-tar.py build <rootfs-dir> <rootfs.manifest> <out.tar.gz> [exclude-file]
                  [dir=prefix ...]

The rootfs is kept as ordinary files owned by the user, so it cannot hold root
ownership, device nodes or setuid bits. The manifest records those by path.
fakeroot's database records them by inode, which breaks when files are moved or
restored from git: the image then loses every device node and cannot boot.

A file not in the manifest gets root:root and its mode on disk. Device nodes and
directories in the manifest are created even if absent from the directory.

Identical image assets with the same owner and mode are stored once, as hard
links, which saves space in the image and on flash. The exclude file lists paths
to leave out; see rootfs/d375.exclude. Each dir=prefix adds a tree of generated files
under that path, owned by root.
A device-node check stops a build that would produce an unbootable image.
"""
import gzip
import hashlib
import os
import stat
import sys
import tarfile

TYPES = {tarfile.DIRTYPE: 'd', tarfile.CHRTYPE: 'c', tarfile.BLKTYPE: 'b',
         tarfile.FIFOTYPE: 'p'}
REQUIRED = ['dev/console', 'dev/null']
MIN_LINK = 600     # below this, a tar header costs as much as the file
# Read-only assets only: writing to one linked file would change the others.
LINK_ONLY = 'snom/bmp/'


def norm(name):
    name = os.path.normpath(name)
    return '' if name == '.' else name


def make_manifest(tar_path, out):
    with tarfile.open(tar_path, 'r:*') as tf, open(out, 'w') as f:
        for m in tf:
            kind = TYPES.get(m.type, 'f')
            f.write(f'{kind} {m.mode:o} {m.uid} {m.gid} {m.devmajor} {m.devminor} '
                    f'{norm(m.name)}\n')


def load(path):
    meta = {}
    for line in open(path):
        kind, mode, uid, gid, major, minor, name = line.rstrip('\n').split(' ', 6)
        meta[name] = (kind, int(mode, 8), int(uid), int(gid), int(major), int(minor))
    return meta


def load_excludes(path):
    if not path:
        return []
    lines = (x.split('#')[0].strip() for x in open(path))
    return [x for x in lines if x]


def excluded(p, rules):
    return any(p == r or (r.endswith('/') and p.startswith(r)) for r in rules)


def build(root, manifest, out, exclude=None, *extras):
    meta = load(manifest)
    rules = load_excludes(exclude)
    paths = set()
    where = {}      # tar path of a generated file -> file on disk
    for extra in extras:
        tree, prefix = extra.split('=')
        where[prefix] = tree
        for base, dirs, files in os.walk(tree):
            for n in dirs + files:
                full = os.path.join(base, n)
                where[os.path.join(prefix, os.path.relpath(full, tree))] = full
    for base, dirs, files in os.walk(root):
        for n in dirs + files:
            p = os.path.relpath(os.path.join(base, n), root)
            if p != '.fakeroot':
                paths.add(p)
    paths |= {p for p, v in meta.items() if v[0] in 'dcbp' and p}
    paths |= set(where)
    paths = {p for p in paths if not excluded(p, rules)}
    seen = {}

    with gzip.GzipFile(out, 'wb', 9, mtime=0) as gz, \
            tarfile.open(fileobj=gz, mode='w', format=tarfile.GNU_FORMAT) as tf:
        for p in sorted(paths):
            full = where.get(p, os.path.join(root, p))
            m = meta.get(p)
            ti = tarfile.TarInfo(p)    # no ./ prefix: see build-custom-firmware.sh
            st = os.lstat(full) if os.path.lexists(full) else None
            ti.mtime = int(st.st_mtime) if st else 0
            ti.uid, ti.gid = (m[2], m[3]) if m else (0, 0)
            if m and m[0] in 'cbp':
                ti.type = {'c': tarfile.CHRTYPE, 'b': tarfile.BLKTYPE,
                           'p': tarfile.FIFOTYPE}[m[0]]
                ti.mode, ti.devmajor, ti.devminor = m[1], m[4], m[5]
                tf.addfile(ti)
            elif st is None or stat.S_ISDIR(st.st_mode):
                ti.type = tarfile.DIRTYPE
                ti.mode = m[1] if m else 0o755
                tf.addfile(ti)
            elif stat.S_ISLNK(st.st_mode):
                ti.type = tarfile.SYMTYPE
                ti.linkname = os.readlink(full)
                ti.mode = 0o777
                tf.addfile(ti)
            else:
                ti.mode = m[1] if m else stat.S_IMODE(st.st_mode)
                with open(full, 'rb') as f:
                    digest = hashlib.sha256(f.read()).digest()
                key = (digest, st.st_size, ti.mode, ti.uid, ti.gid)
                if p.startswith(LINK_ONLY) and st.st_size >= MIN_LINK and key in seen:
                    ti.type = tarfile.LNKTYPE
                    ti.linkname = seen[key]
                    tf.addfile(ti)
                    continue
                seen.setdefault(key, p)
                ti.size = st.st_size
                with open(full, 'rb') as f:
                    tf.addfile(ti, f)
    with tarfile.open(out, 'r:*') as tf:
        for name in REQUIRED:
            if not tf.getmember(name).ischr():
                sys.exit(f'{name} is not a device node; refusing this image')


if sys.argv[1:2] == ['manifest']:
    make_manifest(sys.argv[2], sys.argv[3])
elif sys.argv[1:2] == ['build']:
    build(*sys.argv[2:])
else:
    sys.exit(__doc__)
