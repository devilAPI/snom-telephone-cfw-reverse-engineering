# NES emulator on the snom D375

The **Boot NES** button in the [CFW Settings](cfw-settings.md) panel runs a NES
emulator on the phone's screen and keypad. Engine:
[InfoNES](https://github.com/jay-kumogata/InfoNES) with a snom port
(`nes-src/InfoNES_System_snom.cpp`), built static against musl. Same screen/input
takeover as [Doom](doom.md).

## Reuses the Doom harness

- Video `/dev/fb0` (480x272, 32bpp); NES 256x240 is **centered**, no scaling.
- Input `/dev/input/event0`, freed by killing `lid` + `media_daemon`.
- Takeover via `/tmp/ssh_fast_update`; **quitting reboots the phone** to restore.

Controls: nav pad = D-pad, Fire = A, Use = B, OK = Start, Cancel = Select,
red Hangup = quit.

## ROMs are downloaded from a URL (nothing stored)

The Boot NES button prompts for a **URL to a .nes ROM**. The launcher downloads it
to `/tmp` (RAM), runs it, and deletes it on quit — no ROM is kept on the phone or
in the image. The download happens before the screen takeover, so a bad URL just
reports an error. (Unlike Doom, the filename doesn't matter — InfoNES reads the
iNES header.)

**Compatibility:** mapper 0/1/2/3/4 iNES ROMs work. **NES-2.0 "torture" test
ROMs can crash the emulator** — e.g. the 240p Test Suite renders briefly then
dies; a normal game (mapper 0 NROM) runs fine. Verified on-device with the
MIT-licensed `bbbradsmith/NES-ca65-example` demo.

## Two bugs found during the port (for the record)

1. **Frame pacing.** `InfoNES_Wait()` is called **once per scanline** (~262x per
   frame). Sleeping to 1/60 s there made one frame take ~4 s (black screen,
   ~1 rendered frame every few seconds). Fix: `InfoNES_Wait()` is a no-op and the
   60 Hz pacing lives in `InfoNES_LoadFrame()` (called once per frame).
2. **Framebuffer vs emulation.** A gradient self-test proved the fb path was fine
   while the screen stayed black — which isolated the problem to pacing, not
   rendering. (Debugging was done by dumping `/dev/fb0` to a PNG and looking at
   it, not by eyeballing the phone.)

## Building

`tools/build-nes.sh` (needs docker) clones InfoNES, drops in
`nes-src/InfoNES_System_snom.cpp`, and cross-builds a static musl armv6 binary to
`tools/out/infones`. Copy it to `custom-rootfs/snom/cfw/nes/infones` (root:0755).
Under `/snom`, so the first-boot `cleanUpRootfs` pass leaves it alone.

## Known limitations

- (Sound now works, see below.)
- Save-RAM (battery saves) isn't persisted anywhere.
- Phone can't take calls while the emulator runs; quitting reboots it.

## Sound and pacing (2026-10-30)

InfoNES's APU hands over five unsigned 8-bit channel buffers per frame. The
port mixes them with the 2A03's relative weights (integer, Q4), removes the DC
offset with a one-pole high-pass, and `snd_hal_push_rate()` box-filters the
result down to the codec's 16 kHz (see [sound.md](sound.md)).

- **APU at 22050 Hz** (`tools/build-nes.sh` patches `pAPU_QUALITY` 3 -> 2):
  half the per-sample APU work of 44.1 kHz, still above the 16 kHz output.
- **The audio queue is the clock.** `paceFrame()` runs once per emulated frame
  from `InfoNES_SoundOutput()` (InfoNES calls it every frame, while
  `InfoNES_LoadFrame()` is skipped on frameskipped frames) and sleeps off
  anything above 100 ms queued. Below 50 ms it sets `FrameSkip = 1` for one
  frame (never two in a row).
- **RGB555 lookup table** for the 256x240 frame copy, `-march=armv6 -marm`.
- **lcsD375 is SIGSTOPped** after the takeover (as Doom does): it survives the
  kill of its parent lid and painted "MediaStack restarting" around the game.

Measured with `tests/roms/tone.nes` (hand-made: pulse arpeggio + 220 Hz
triangle, `tests/roms/mkroms.py`), `NES_STATS=1`: before **55–57 fps, 10–30
underruns per 5 s** (CPU-bound, 0 % idle); after **60.0 fps, 0 underruns, ~45 %
CPU**. The FFT (`tests/fftcheck.py`) finds the triangle in every window and
all arpeggio notes; InfoNES's pulse pitch is ~0.5–1 % sharp (its own
frequency constants), inaudible.
