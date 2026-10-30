#!/usr/bin/env python3
"""Build the hand-made emulator test ROMs (no toolchain needed for NES/GB).

  tone.nes     NROM: light-blue screen; pulse 1 arpeggio A4 C#5 E5 A5 C#6 A5 E5 C#5
               (one note per 16 frames) + triangle at 220 Hz.
  sndtest.gb   CGB-compatible ROM-only: four vertical colour bars (red, green, blue,
               white); CH1 square arpeggio (same notes, 16 frames each) + CH2 at 220 Hz.
  sndtest.gba  built from sndtest-gba.S by build.sh (needs clang/ld.lld).

All three are original code written for the snom D375 CFW tests; the expected
frequencies are listed in EXPECT below and checked by tests/fftcheck.py.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))

class Asm:
    """Tiny label-resolving byte assembler: emit bytes, ('abs', label) for a
    16-bit little-endian address, ('rel', label) for an 8-bit relative branch."""
    def __init__(self, org):
        self.org, self.items, self.labels = org, [], {}
    def label(self, name):
        self.labels[name] = self.org + sum(1 if isinstance(i, int) else (2 if i[0] == 'abs' else 1) for i in self.items)
    def __call__(self, *xs):
        for x in xs:
            self.items.append(x)
    def assemble(self):
        out, pc = bytearray(), self.org
        for i in self.items:
            if isinstance(i, int):
                out.append(i & 0xff); pc += 1
            elif i[0] == 'abs':
                a = self.labels[i[1]]; out += bytes((a & 0xff, a >> 8)); pc += 2
            else:  # rel: relative to the address after this operand byte
                d = self.labels[i[1]] - (pc + 1)
                assert -128 <= d <= 127, i
                out.append(d & 0xff); pc += 1
        return bytes(out)

L = lambda n: ('abs', n)
R = lambda n: ('rel', n)

# ---------------------------------------------------------------- NES
def nes():
    CPU = 1789773
    notes = [440.0, 554.37, 659.26, 880.0, 1108.73, 880.0, 659.26, 554.37]
    timers = [round(CPU / (16 * f)) - 1 for f in notes]
    a = Asm(0xC000)
    a.label('reset')
    a(0x78, 0xD8, 0xA2, 0xFF, 0x9A)                    # SEI CLD LDX #$FF TXS
    a(0xA9, 0x00, 0x8D, 0x00, 0x20, 0x8D, 0x01, 0x20)  # PPUCTRL=PPUMASK=0
    for n in ('vb1', 'vb2'):                           # two vblanks: PPU warm-up
        a.label(n); a(0x2C, 0x02, 0x20, 0x10, R(n))
    a(0xA9, 0x3F, 0x8D, 0x06, 0x20, 0xA9, 0x00, 0x8D, 0x06, 0x20)   # PPUADDR=$3F00
    a(0xA9, 0x21, 0x8D, 0x07, 0x20)                    # backdrop = $21 light blue
    a(0xA9, 0x00, 0x8D, 0x05, 0x20, 0x8D, 0x05, 0x20)  # scroll 0,0
    a(0xA9, 0x05, 0x8D, 0x15, 0x40)                    # APU: pulse 1 + triangle on
    a(0xA9, 0xBF, 0x8D, 0x00, 0x40)                    # pulse1 50% duty, halt, const vol 15
    a(0xA9, 0x08, 0x8D, 0x01, 0x40)                    # no sweep
    a(0xA9, 0xFF, 0x8D, 0x08, 0x40)                    # triangle: halt + linear reload 127
    tri = round(CPU / (32 * 220.0)) - 1
    a(0xA9, tri & 0xff, 0x8D, 0x0A, 0x40, 0xA9, 0x08 | (tri >> 8), 0x8D, 0x0B, 0x40)
    a(0xA9, 0x00, 0x85, 0x00, 0x85, 0x01)              # frame=0 note=0 (zero page)
    a(0xA9, 0x0A, 0x8D, 0x01, 0x20)                    # BG on (all tiles blank -> backdrop)
    a(0xA9, 0x80, 0x8D, 0x00, 0x20)                    # NMI on
    a.label('loop'); a(0x4C, L('loop'))
    a.label('nmi')
    a(0x48, 0x8A, 0x48)                                # PHA TXA PHA
    a(0xA5, 0x00, 0x29, 0x0F, 0xD0, R('done'))         # every 16th frame:
    a(0xA6, 0x01)                                      #   LDX note
    a(0xBD, L('tlo'), 0x8D, 0x02, 0x40)                #   $4002 = lo
    a(0xBD, L('thi'), 0x09, 0x08, 0x8D, 0x03, 0x40)    #   $4003 = hi | length
    a(0xE8, 0x8A, 0x29, 0x07, 0x85, 0x01)              #   note = (note+1)&7
    a.label('done')
    a(0xE6, 0x00)                                      # frame++
    a(0x68, 0xAA, 0x68, 0x40)                          # PLA TAX PLA RTI
    a.label('irq'); a(0x40)
    a.label('tlo'); a(*[t & 0xff for t in timers])
    a.label('thi'); a(*[t >> 8 for t in timers])
    code = a.assemble()
    prg = bytearray(b'\xff' * 0x4000)
    prg[:len(code)] = code
    vec = lambda n: bytes((a.labels[n] & 0xff, a.labels[n] >> 8))
    prg[0x3FFA:0x4000] = vec('nmi') + vec('reset') + vec('irq')
    hdr = b'NES\x1a' + bytes((1, 1, 0, 0)) + bytes(8)
    real = [CPU / (16 * (t + 1)) for t in timers]
    return hdr + bytes(prg) + bytes(0x2000), real, CPU / (32 * (tri + 1))

# ---------------------------------------------------------------- GB / GBC
LOGO = bytes.fromhex('CEED6666CC0D000B03730083000C000D0008111F8889000EDCCC6EE6DDDDD999'
                     'BBBB67636E0EECCCDDDC999FBBB9333E')

def gb():
    notes = [440.0, 554.37, 659.26, 880.0, 1108.73, 880.0, 659.26, 554.37]
    regs = [2048 - round(131072 / f) for f in notes]
    low = 2048 - round(131072 / 220.0)
    a = Asm(0x150)
    a(0xF3, 0x31, 0xFE, 0xFF)                          # DI; LD SP,$FFFE
    a.label('w0'); a(0xF0, 0x44, 0xFE, 0x90, 0x20, R('w0'))   # wait LY==144
    a(0xAF, 0xE0, 0x40)                                # LCD off
    a(0x21, 0x10, 0x80, 0x11, L('tiles'), 0x0E, 48)    # HL=$8010 DE=tiles C=48
    a.label('t1'); a(0x1A, 0x22, 0x13, 0x0D, 0x20, R('t1'))
    a(0x21, 0x00, 0x98, 0x06, 18)                      # HL=$9800 B=18 rows
    a.label('r1'); a(0x11, L('row'), 0x0E, 32)
    a.label('c1'); a(0x1A, 0x22, 0x13, 0x0D, 0x20, R('c1'))
    a(0x05, 0x20, R('r1'))
    a(0x3E, 0x80, 0xE0, 0x68, 0x21, L('pal'), 0x0E, 8) # CGB BG palette 0, auto-inc
    a.label('p1'); a(0x2A, 0xE0, 0x69, 0x0D, 0x20, R('p1'))
    a(0x3E, 0xE4, 0xE0, 0x47)                          # DMG BGP (fallback)
    a(0xAF, 0xE0, 0x42, 0xE0, 0x43)                    # scroll 0
    a(0x3E, 0x91, 0xE0, 0x40)                          # LCD on, BG on, tiles at $8000
    a(0x3E, 0x80, 0xE0, 0x26, 0x3E, 0x77, 0xE0, 0x24, 0x3E, 0x33, 0xE0, 0x25)
    a(0xAF, 0xE0, 0x10, 0x3E, 0x80, 0xE0, 0x11, 0x3E, 0xF0, 0xE0, 0x12)
    a(0x3E, 0x80, 0xE0, 0x16, 0x3E, 0xA0, 0xE0, 0x17)
    a(0x3E, low & 0xff, 0xE0, 0x18, 0x3E, 0x80 | (low >> 8), 0xE0, 0x19)
    a(0x0E, 0x00)                                      # C = note index
    a.label('note')
    a(0x21, L('notes'), 0x06, 0x00, 0x09, 0x09)        # HL = notes + 2*C
    a(0x2A, 0xE0, 0x13, 0x7E, 0xF6, 0x80, 0xE0, 0x14)  # NR13/NR14 (trigger)
    a(0x0C, 0x79, 0xE6, 0x07, 0x4F)                    # C = (C+1)&7
    a(0x16, 16)                                        # D = 16 frames
    a.label('fr')
    a.label('w1'); a(0xF0, 0x44, 0xFE, 0x90, 0x20, R('w1'))
    a.label('w2'); a(0xF0, 0x44, 0xFE, 0x90, 0x28, R('w2'))
    a(0x15, 0x20, R('fr'), 0x18, R('note'))
    a.label('tiles')
    a(*([0xFF, 0x00] * 8 + [0x00, 0xFF] * 8 + [0xFF, 0xFF] * 8))  # colours 1,2,3
    a.label('row'); a(*([0] * 5 + [1] * 5 + [2] * 5 + [3] * 5 + [0] * 12))
    rgb = lambda r, g, b: r | g << 5 | b << 10
    a.label('pal')
    for c in (rgb(31, 0, 0), rgb(0, 31, 0), rgb(0, 0, 31), rgb(31, 31, 31)):
        a(c & 0xff, c >> 8)
    a.label('notes')
    for r in regs: a(r & 0xff, r >> 8)
    code = a.assemble()
    rom = bytearray(0x8000)
    rom[0x100:0x104] = bytes((0x00, 0xC3, 0x50, 0x01))
    rom[0x104:0x134] = LOGO
    rom[0x134:0x13B] = b'SNDTEST'
    rom[0x143] = 0x80
    rom[0x150:0x150 + len(code)] = code
    x = 0
    for i in range(0x134, 0x14D): x = (x - rom[i] - 1) & 0xff
    rom[0x14D] = x
    s = sum(rom) & 0xffff
    rom[0x14E:0x150] = bytes((s >> 8, s & 0xff))
    return bytes(rom), [131072 / (2048 - r) for r in regs], 131072 / (2048 - low)

if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else HERE
    for name, fn in (('tone.nes', nes), ('sndtest.gb', gb)):
        data, arp, bass = fn()
        open(os.path.join(out, name), 'wb').write(data)
        print('%s: arpeggio %s Hz, constant %.1f Hz' % (name, ' '.join('%.1f' % f for f in arp), bass))
