#!/usr/bin/env python3
"""Read a D815 kernel: unpack it, recover its symbols, disassemble functions.

    kernel-dis.py <uImage> syms [regex]      list symbols
    kernel-dis.py <uImage> dis NAME [NAME..] disassemble functions

The kernel is LZMA-compressed and keeps kallsyms. Needs python capstone.
"""
import bisect
import lzma
import re
import struct
import sys

BASE = 0xd0008000


def unpack(path):
    d = open(path, 'rb').read()[64:]
    for m in re.finditer(b'\x5d\0\0', d):
        try:
            x = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE).decompress(d[m.start():])
            if len(x) > 1000000:
                return x
        except lzma.LZMAError:
            pass
    sys.exit('no LZMA kernel found')


def symbols(d):
    w = lambda o: struct.unpack('<I', d[o:o + 4])[0]
    best = (0, 0)
    o = 0
    n = len(d) & ~3
    while o < n:
        v = w(o)
        if 0xd0000000 <= v < 0xd1000000:
            s, p = o, v
            o += 4
            while o < n and p <= w(o) < 0xd1000000:
                p = w(o)
                o += 4
            if o - s > best[1]:
                best = (s, o - s)
        else:
            o += 4
    start, size = best
    o = start + size
    while w(o) == 0:
        o += 4
    num = w(o)
    o += 4
    o = (o + 15) & ~15 if w(o) == 0 else o
    while w(o) == 0:
        o += 4
    names = p = o
    for _ in range(num):
        p += d[p] + 1
    mark = (p + 15) & ~15
    tok = (mark + ((num + 255) // 256) * 4 + 15) & ~15
    toks = []
    r = tok
    for _ in range(256):
        e = d.index(b'\0', r)
        toks.append(d[r:e].decode('latin1'))
        r = e + 1
    out = []
    p = names
    for i in range(num):
        n = d[p]
        s = ''.join(toks[b] for b in d[p + 1:p + 1 + n])
        p += n + 1
        out.append((w(start + i * 4), s[0], s[1:]))
    return out


def dis(d, syms, names):
    import capstone
    addrs = [s[0] for s in syms]
    by = {s[2]: s[0] for s in syms}

    def sym(a):
        i = bisect.bisect(addrs, a) - 1
        return f'{syms[i][2]}+{a - addrs[i]:#x}' if a >= 0xd0000000 and i >= 0 else hex(a)

    md = capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_ARM)
    for name in names:
        a = by[name]
        j = bisect.bisect(addrs, a)
        while addrs[j] == a:
            j += 1
        print(f'== {name} {a:x}-{addrs[j]:x}')
        for p in range(a, addrs[j], 4):
            w = d[p - BASE:p - BASE + 4]
            x = list(md.disasm(w, p))
            if not x:
                print(f'{p:x}: .word {struct.unpack("<I", w)[0]:#x}')
                continue
            t = x[0].op_str
            if x[0].mnemonic in ('bl', 'b') and t.startswith('#'):
                t = sym(int(t[1:], 16))
            if x[0].mnemonic == 'ldr' and 'pc, #' in t:
                o = int(t.split('#')[1].rstrip(']'), 16)
                v = struct.unpack('<I', d[p + 8 + o - BASE:p + 12 + o - BASE])[0]
                t += f' ; ={v:#x}'
            print(f'{p:x}: {x[0].mnemonic} {t}')


kernel = unpack(sys.argv[1])
table = symbols(kernel)
if sys.argv[2] == 'syms':
    rx = re.compile(sys.argv[3] if len(sys.argv) > 3 else '.')
    for a, t, n in table:
        if rx.search(n):
            print(f'{a:08x} {t} {n}')
else:
    dis(kernel, table, sys.argv[3:])
