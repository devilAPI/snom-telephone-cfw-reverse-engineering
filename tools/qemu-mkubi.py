#!/usr/bin/env python3
"""Build the raw NAND image for the snom-d815 QEMU machine.

    qemu-mkubi.py <rootfs.ubifs> <nand.img> [--overlay overlay.ubifs]

Does the job of ubinize: wraps a UBIFS image into UBI volumes on a 256 MiB
flash of 2048+64 byte pages. Volumes: rootfs1 (the image), overlay (mounted by
rcS, formatted by UBIFS on first mount unless --overlay gives one).
"""
import argparse
import os
import struct
import zlib

PAGE, OOB, PPB, PEBS = 2048, 64, 64, 2048
PEB = PAGE * PPB
VID_OFF, DATA_OFF = PAGE, 2 * PAGE
LEB = PEB - DATA_OFF
LAYOUT_ID = 0x7fffefff
IMAGE_SEQ = 0x1a2b3c4d
VOL_DYNAMIC = 1
VTBL_REC = 172
COMPAT_REJECT = 5


def crc(b):
    return (zlib.crc32(b) ^ 0xffffffff) & 0xffffffff


def ec_hdr():
    h = b'UBI#' + struct.pack('>B3xQIII32x', 1, 0, VID_OFF, DATA_OFF, IMAGE_SEQ)
    return h + struct.pack('>I', crc(h))


def vid_hdr(vol_id, lnum, sqnum, compat=0):
    h = b'UBI!' + struct.pack('>BBBBII4xIIII4xQ12x', 1, VOL_DYNAMIC, 0, compat,
                              vol_id, lnum, 0, 0, 0, 0, sqnum)
    return h + struct.pack('>I', crc(h))


def vtbl_rec(name=None, pebs=0):
    if name is None:
        r = bytes(VTBL_REC - 4)
    else:
        n = name.encode()
        r = struct.pack('>IIIBBH', pebs, 1, 0, VOL_DYNAMIC, 0, len(n))
        r += n.ljust(128, b'\0') + bytes(24)
    return r + struct.pack('>I', crc(r))


class Image:
    def __init__(self):
        self.raw = bytearray(b'\xff' * (PEBS * PPB * (PAGE + OOB)))
        self.next_peb = 0
        self.sqnum = 0

    def put(self, offset, data):
        """offset is in PEB address space; OOB bytes stay erased."""
        for off in range(0, len(data), PAGE):
            page = (offset + off) // PAGE
            chunk = data[off:off + PAGE]
            pos = page * (PAGE + OOB)
            self.raw[pos:pos + len(chunk)] = chunk

    def leb(self, vol_id, lnum, data, compat=0):
        peb = self.next_peb * PEB
        self.next_peb += 1
        self.sqnum += 1
        self.put(peb, ec_hdr())
        self.put(peb + VID_OFF, vid_hdr(vol_id, lnum, self.sqnum, compat))
        self.put(peb + DATA_OFF, data)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('ubifs')
    ap.add_argument('output')
    ap.add_argument('--overlay')
    a = ap.parse_args()

    root = open(a.ubifs, 'rb').read()
    over = open(a.overlay, 'rb').read() if a.overlay else b''
    img = Image()

    root_pebs = 900
    overlay_pebs = 400
    table = bytearray()
    for i in range(LEB // VTBL_REC if LEB // VTBL_REC < 128 else 128):
        if i == 0:
            table += vtbl_rec('rootfs1', root_pebs)
        elif i == 1:
            table += vtbl_rec('overlay', overlay_pebs)
        else:
            table += vtbl_rec()
    img.leb(LAYOUT_ID, 0, bytes(table), COMPAT_REJECT)
    img.leb(LAYOUT_ID, 1, bytes(table), COMPAT_REJECT)

    for vol, blob in ((0, root), (1, over)):
        for lnum in range(0, len(blob), LEB):
            chunk = blob[lnum:lnum + LEB]
            if chunk.strip(b'\xff'):
                img.leb(vol, lnum // LEB, chunk.rstrip(b'\xff'))

    tmp = a.output + '.tmp'
    with open(tmp, 'wb') as f:
        f.write(img.raw)
    os.replace(tmp, a.output)
    print(f'{a.output}: {img.next_peb} PEBs used of {PEBS}')


if __name__ == '__main__':
    main()
