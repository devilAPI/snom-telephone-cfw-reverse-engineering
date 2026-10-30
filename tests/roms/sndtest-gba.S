@ GBA test ROM for the snom D375 CFW (original code). ARM mode only.
@ Screen: mode 3, eight vertical 30-px colour bars:
@   red green blue yellow cyan magenta white grey
@ Sound: PSG channel 1 square arpeggio A4 C#5 E5 A5 C#6 A5 E5 C#5, one note per
@ 16 frames, plus channel 2 square at 220 Hz. Rates: f = 131072 / (2048 - x).
        .arm
        .section .text
        .global _start
_start:
        b       main
        .space  0xBC                    @ logo + header (filled in by build.sh)
main:
        mov     r0, #0x04000000
        ldr     r1, =0x0403             @ DISPCNT: mode 3, BG2 on
        strh    r1, [r0]
        @ --- colour bars ---
        mov     r2, #0x06000000         @ VRAM
        mov     r3, #160                @ rows
1:      adr     r4, colours
        mov     r5, #8                  @ bars
2:      ldrh    r6, [r4], #2
        mov     r7, #30
3:      strh    r6, [r2], #2
        subs    r7, r7, #1
        bne     3b
        subs    r5, r5, #1
        bne     2b
        subs    r3, r3, #1
        bne     1b
        @ --- sound ---
        mov     r1, #0x80
        strh    r1, [r0, #0x84]         @ SOUNDCNT_X: master on
        ldr     r1, =0x3377
        strh    r1, [r0, #0x80]         @ SOUNDCNT_L: ch1+ch2 L/R, vol 7
        mov     r1, #2
        strh    r1, [r0, #0x82]         @ SOUNDCNT_H: PSG 100%
        mov     r1, #0x08               @ sweep off (negate=1, shift 0)
        strh    r1, [r0, #0x60]
        ldr     r1, =0xF080             @ ch1: vol 15, 50% duty
        strh    r1, [r0, #0x62]
        ldr     r1, =0xA080             @ ch2: vol 10, 50% duty
        strh    r1, [r0, #0x68]
        ldr     r1, =(0x8000 | (2048 - 596))   @ ch2 220 Hz, trigger
        strh    r1, [r0, #0x6C]
        mov     r8, #0                  @ note index
note:
        adr     r4, notes
        add     r4, r4, r8, lsl #1
        ldrh    r1, [r4]
        orr     r1, r1, #0x8000         @ trigger
        strh    r1, [r0, #0x64]
        add     r8, r8, #1
        and     r8, r8, #7
        mov     r9, #16
frame:
4:      ldrh    r1, [r0, #6]            @ VCOUNT
        cmp     r1, #160
        bne     4b
5:      ldrh    r1, [r0, #6]
        cmp     r1, #160
        beq     5b
        subs    r9, r9, #1
        bne     frame
        b       note

colours:
        .hword  0x001F, 0x03E0, 0x7C00, 0x03FF, 0x7FE0, 0x7C1F, 0x7FFF, 0x4210
notes:
        .hword  2048-298, 2048-236, 2048-199, 2048-149, 2048-118, 2048-149, 2048-199, 2048-236
        .ltorg
