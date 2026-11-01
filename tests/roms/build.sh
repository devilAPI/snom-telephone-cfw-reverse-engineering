#!/usr/bin/env bash
# Rebuild the emulator test ROMs: tone.nes, sndtest.gb (python) and sndtest.gba
# (clang + ld.lld, host tools). The committed binaries are what tests/retro.sh uses.
set -euo pipefail
cd "$(dirname "$0")"
python3 mkroms.py .
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
clang --target=armv4t-none-eabi -c sndtest-gba.S -o "$T/g.o"
ld.lld -Ttext=0x08000000 -e _start "$T/g.o" -o "$T/g.elf"
llvm-objcopy -O binary "$T/g.elf" "$T/g.bin"
python3 - "$T/g.bin" sndtest.gba <<'PY'
import sys
rom = bytearray(open(sys.argv[1], 'rb').read())
rom[0xA0:0xAC] = b'SNDTEST'.ljust(12, b'\0')   # title
rom[0xAC:0xB0] = b'ZSND'                        # game code
rom[0xB0:0xB2] = b'00'                          # maker
rom[0xB2] = 0x96                                # fixed value
c = 0
for b in rom[0xA0:0xBD]: c = (c - b) & 0xff
rom[0xBD] = (c - 0x19) & 0xff                   # header complement check
rom += bytes(0x8000 - len(rom))              # pad to 32 KiB
open(sys.argv[2], 'wb').write(rom)
print('sndtest.gba: %d bytes' % len(rom))
PY

clang --target=armv4t-none-eabi -c sav-gba.S -o "$T/s.o"
ld.lld -Ttext=0x08000000 -e _start "$T/s.o" -o "$T/s.elf"
llvm-objcopy -O binary "$T/s.elf" "$T/s.bin"
python3 - "$T/s.bin" sav.gba <<'PY'
import sys
rom = bytearray(open(sys.argv[1], 'rb').read())
rom[0xA0:0xAC] = b'SAVTEST'.ljust(12, b'\0')   # title
rom[0xAC:0xB0] = b'ZSAV'                        # game code
rom[0xB0:0xB2] = b'00'                          # maker
rom[0xB2] = 0x96                                # fixed value
c = 0
for b in rom[0xA0:0xBD]: c = (c - b) & 0xff
rom[0xBD] = (c - 0x19) & 0xff                   # header complement check
rom += bytes(0x8000 - len(rom))              # pad to 32 KiB
open(sys.argv[2], 'wb').write(rom)
print('sav.gba: %d bytes' % len(rom))
PY
