@ GBA save test ROM (original code): increments byte 0 of cartridge SRAM (0xFF = blank = 0)
@ (0x0E000000) on every start, then idles. The "SRAM_V113" tag tells emulators
@ the save type.
        .arm
        .section .text
        .global _start
_start:
        b       main
        .space  0xBC
main:
        ldr     r0, =0x0E000000
        ldrb    r1, [r0]
        cmp     r1, #255                @ blank SRAM reads 0xFF: count from 0
        moveq   r1, #0
        add     r1, r1, #1
        strb    r1, [r0]
1:      b       1b
        .ltorg
        .balign 4
        .ascii  "SRAM_V113"
        .balign 4
