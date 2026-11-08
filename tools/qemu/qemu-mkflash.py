#!/usr/bin/env python3
"""Build the raw NAND image for the snom-d375 QEMU machine.

    qemu-mkflash.py <rootfs.tar.gz> <nand.img> [--protected DIR]

The image is what the phone's flash would hold: 65536 pages of 2048+64 bytes,
partitioned as in the kernel command line. A firmware .bin contains a
rootfs.tar.gz, so owners, modes and device nodes come straight from that
tarball, with no fakeroot and no mkfs.jffs2.

Only two partitions get content: mtd7 (rootfs) and mtd5 (/protected). Both are
little-endian JFFS2 without clean markers, which is what mkfs.jffs2 -n would
produce for NAND. Blank blocks are left for JFFS2 to erase on first mount.
"""
import argparse
import gzip
import os
import stat
import struct
import sys
import tarfile
import zlib

PAGE = 2048
OOB = 64
PAGES = 65536
ERASE = 128 * 1024

MTD5_DATA = (0x00E00000, 0x000C0000)
MTD7_ROOTFS = (0x012C0000, 0x06D40000)

COMPR_NONE = 0
COMPR_ZLIB = 6
MAGIC = 0x1985
NT_DIRENT = 0xE001
NT_INODE = 0xE002
DT = {stat.S_IFDIR: 4, stat.S_IFREG: 8, stat.S_IFLNK: 10, stat.S_IFCHR: 2,
      stat.S_IFBLK: 6, stat.S_IFIFO: 1, stat.S_IFSOCK: 12}


def crc(b):
    """crc32_le with seed 0 and no final inversion, as JFFS2 uses it."""
    return (zlib.crc32(b, 0xffffffff) ^ 0xffffffff) & 0xffffffff


class Jffs2:
    def __init__(self):
        self.out = bytearray()
        self.next_ino = 2

    def _put(self, node):
        """Append a node, keeping it inside one erase block and 4-aligned."""
        room = ERASE - (len(self.out) % ERASE)
        if len(node) > room:
            self.out += b'\xff' * room
        self.out += node
        self.out += b'\xff' * (-len(self.out) % 4)

    def dirent(self, pino, version, ino, name, dtype, mtime):
        name = name.encode()
        hdr = struct.pack('<HHI', MAGIC, NT_DIRENT, 40 + len(name))
        hdr += struct.pack('<I', crc(hdr))
        body = hdr + struct.pack('<IIIIBBBB', pino, version, ino, mtime,
                                 len(name), dtype, 0, 0)
        node = body + struct.pack('<II', crc(body), crc(name)) + name
        self._put(node)

    def inode(self, ino, version, mode, uid, gid, isize, mtime, offset,
              data, dsize, compr):
        hdr = struct.pack('<HHI', MAGIC, NT_INODE, 68 + len(data))
        hdr += struct.pack('<I', crc(hdr))
        body = hdr + struct.pack('<IIIHHIIIIIIIBBH', ino, version, mode,
                                 uid & 0xffff, gid & 0xffff, isize, mtime,
                                 mtime, mtime, offset, len(data), dsize,
                                 compr, 0, 0)
        # node_crc covers the 60 bytes before data_crc, not data_crc itself
        node = (body + struct.pack('<II', crc(data), crc(body)) + data)
        self._put(node)

    def file_nodes(self, ino, mode, uid, gid, mtime, data):
        if not data:
            self.inode(ino, 1, mode, uid, gid, 0, mtime, 0, b'', 0, COMPR_NONE)
            return
        version = 0
        for off in range(0, len(data), 4096):
            chunk = data[off:off + 4096]
            packed = zlib.compress(chunk, 9)
            version += 1
            if len(packed) < len(chunk):
                self.inode(ino, version, mode, uid, gid, len(data), mtime,
                           off, packed, len(chunk), COMPR_ZLIB)
            else:
                self.inode(ino, version, mode, uid, gid, len(data), mtime,
                           off, chunk, len(chunk), COMPR_NONE)


def add_tree(fs, entries):
    """entries: list of (path, st_mode, uid, gid, mtime, payload bytes)."""
    inos = {'': 1}
    hard = {}
    for path, mode, uid, gid, mtime, payload in sorted(entries,
                                                       key=lambda e: e[0]):
        if not path:
            continue
        parent, _, name = path.rpartition('/')
        if parent not in inos:
            sys.exit(f'missing parent directory for {path}')
        if isinstance(payload, str):        # hard link: payload is the target
            ino, dtype = hard[payload]
            fs.dirent(inos[parent], 1, ino, name, dtype, mtime)
            continue
        ino = fs.next_ino
        fs.next_ino += 1
        inos[path] = ino
        dtype = DT[stat.S_IFMT(mode)]
        hard[path] = (ino, dtype)
        fs.dirent(inos[parent], 1, ino, name, dtype, mtime)
        if stat.S_ISDIR(mode):
            fs.inode(ino, 1, mode, uid, gid, 0, mtime, 0, b'', 0, COMPR_NONE)
        else:
            fs.file_nodes(ino, mode, uid, gid, mtime, payload)


def tar_entries(path):
    entries = []
    with tarfile.open(path, 'r:*') as tf:
        for m in tf:
            p = os.path.normpath(m.name).lstrip('./')
            if p == '.':
                p = ''
            perm = m.mode & 0o7777
            if m.isdir():
                mode, data = stat.S_IFDIR | perm, b''
            elif m.islnk():
                entries.append((p, stat.S_IFREG | perm, m.uid, m.gid, m.mtime,
                                os.path.normpath(m.linkname).lstrip('./')))
                continue
            elif m.issym():
                mode, data = stat.S_IFLNK | 0o777, m.linkname.encode()
            elif m.ischr() or m.isblk():
                kind = stat.S_IFCHR if m.ischr() else stat.S_IFBLK
                mode = kind | perm
                # old_encode_dev: the two-byte form the kernel falls back to
                data = struct.pack('<H', (m.devmajor << 8) | m.devminor)
            elif m.isfifo():
                mode, data = stat.S_IFIFO | perm, b''
            elif m.isreg():
                mode, data = stat.S_IFREG | perm, tf.extractfile(m).read()
            else:
                continue
            entries.append((p, mode, m.uid, m.gid, m.mtime, data))
    return entries


# The voice DSP cannot be emulated, so the real media_daemon can never start.
# lcsD375 only needs something accepting on its media port to stay out of the
# "MediaStack restarting" state.
MEDIA_STUB = b"""#!/bin/sh
# qemu: stand-in for media_daemon, see docs/qemu.md
while :; do
    sleep 100000 | busybox nc -l -p 1299 >>/tmp/mediaipc.log 2>&1
    sleep 1
done
"""


def patch_rcs(entries):
    """Emulator-only changes: a root shell on UART B, a media_daemon stub."""
    out = []
    for e in entries:
        if e[0] == 'etc/init.d/rcS':
            old = b'    loadKernelModules\n'
            if e[5].count(old) != 1:
                sys.exit('rcS layout changed; cannot add the debug shell')
            e = e[:5] + (e[5].replace(old, (b'    (/bin/sh -i </dev/ttyAMA1 '
                                            b'>/dev/ttyAMA1 2>&1 &) # qemu\n')
                                       + old),)
        elif e[0] == 'snom/media_daemon':
            e = e[:1] + (stat.S_IFREG | 0o755,) + e[2:5] + (MEDIA_STUB,)
        out.append(e)
    return out


def dir_entries(root):
    entries = [('', stat.S_IFDIR | 0o755, 0, 0, 0, b'')]
    for base, dirs, files in os.walk(root):
        for n in sorted(dirs) + sorted(files):
            full = os.path.join(base, n)
            p = os.path.relpath(full, root)
            st = os.lstat(full)
            if stat.S_ISDIR(st.st_mode):
                entries.append((p, st.st_mode, 0, 0, int(st.st_mtime), b''))
            else:
                with open(full, 'rb') as f:
                    entries.append((p, st.st_mode, 0, 0, int(st.st_mtime),
                                    f.read()))
    return entries


def place(img, part, data):
    """Copy a filesystem into the page+OOB layout of the image."""
    start, size = part
    if len(data) > size:
        sys.exit(f'filesystem ({len(data)}) larger than partition ({size})')
    for off in range(0, len(data), PAGE):
        page = (start + off) // PAGE
        chunk = data[off:off + PAGE]
        img[page * (PAGE + OOB):page * (PAGE + OOB) + len(chunk)] = chunk


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('tarball')
    ap.add_argument('output')
    ap.add_argument('--protected', help='directory to put in /protected')
    a = ap.parse_args()

    img = bytearray(b'\xff' * (PAGES * (PAGE + OOB)))

    root = Jffs2()
    add_tree(root, patch_rcs(tar_entries(a.tarball)))
    place(img, MTD7_ROOTFS, root.out)

    prot = Jffs2()
    if a.protected:
        add_tree(prot, dir_entries(a.protected))
    else:
        prot.dirent(1, 1, 2, '.emulated', 8, 0)
        prot.file_nodes(2, stat.S_IFREG | 0o644, 0, 0, 0, b'')
    place(img, MTD5_DATA, prot.out)

    tmp = a.output + '.tmp'
    with open(tmp, 'wb') as f:
        f.write(img)
    os.replace(tmp, a.output)
    print(f'{a.output}: rootfs {len(root.out)} bytes '
          f'({100 * len(root.out) // MTD7_ROOTFS[1]}% of mtd7), '
          f'{root.next_ino - 2} inodes')


if __name__ == '__main__':
    main()
