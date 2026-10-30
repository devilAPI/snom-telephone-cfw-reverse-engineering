# Game Boy Advance emulator (gpSP) on the snom D375

The **Boot GBA** card in the CFW panel (and *Settings → Games → Game Boy
Advance* on the phone) downloads a `.gba` ROM into RAM and runs it on the
phone's screen and keypad with [gpSP](https://github.com/libretro/gpsp), the
libretro core with an ARM dynarec. Quitting (red hangup key) brings the phone
app back. Game Boy / Color uses the same frontend with a different core, see
[gb.md](gb.md).

## Why gpSP

The D375's CPU is an ARM1176 at ~500 MHz (BogoMIPS 498), **armv6 without a
usable FPU**, 120 MB RAM. mGBA/VBA-M interpret the ARM7TDMI and need several
times that. gpSP recompiles GBA ARM/Thumb code into native ARM code, which is
the only realistic way to full speed on this class of CPU (it was written for
the 333 MHz PSP and runs on the Raspberry Pi 1, the same ARM1176 core).

Measured on the device with the test ROM: a steady 59.6–59.7 fps (the GBA's
59.73 Hz) at ~54 % CPU, no audio underruns, see [Measurements](#measurements).

## How it fits together

```
retro-src/snom_retro.c  -- the whole "RetroArch": fb / evdev / snd_hal / pacing
        + libcore.a     -- gpSP built with platform=unix CPU_ARCH=arm HAVE_DYNAREC=1
        + snd/snd_hal.c -- halaudio loudspeaker output (docs/sound.md)
  = /snom/cfw/gba/gpsp  (static musl, armv6, soft-float)
```

- **Video**: the core hands over 240x160 RGB565. The frontend scales it to the
  largest box with the core's aspect ratio that fits 480x272: **408x272
  (x1.7)**, centred, with 36 px black borders. Nearest neighbour through
  precomputed row/column maps and a 64K-entry RGB565→XRGB8888 table; a source
  row that maps to several screen rows is drawn once and `memcpy`'d.
- **Input**: `/dev/input/event0`, grabbed (`EVIOCGRAB`) after the takeover.
- **Audio**: gpSP mixes stereo at 32768 Hz. The frontend downmixes to mono and
  `snd_hal_push_rate()` box-filters it down to the codec's 16 kHz (integer
  only, state carried across calls).
- **Pacing**: the codec drains our ring at exactly 16 kHz, so it is the
  clock. Before every frame the frontend looks at `snd_hal_queued()`: above
  100 ms it sleeps off the excess, so the game runs at the audio rate and can
  never drift into periodic underruns or overflow. gpSP's own *auto frameskip*
  gets the same number through the libretro audio-buffer-status callback
  (occupancy in % of 100 ms, "underrun likely" below 25 ms). When the queue is
  below 50 ms the frontend also skips its own blit for that frame.
- **The ROM is loaded before the takeover.** If gpSP refuses the file the
  engine exits with code 2 while lid/media_daemon are still alive, and the
  launcher reports the error without touching the phone UI.
- **lcsD375** (the phone UI renderer) survives the takeover and painted
  "MediaStack restarting" into our borders in the first test; the engine now
  SIGSTOPs it, as Doom does, and wipes the borders every 64 frames anyway.

## Keys

| Phone key            | GBA     | evdev code |
|----------------------|---------|-----------:|
| nav up/down/left/right | D-pad | 84 / 67 / 101 / 50 |
| Fire                 | A       | 120 |
| Use                  | B       | 116 |
| OK                   | Start   | 97 |
| Cancel               | Select  | 115 |
| digit **1**          | **L**   | 51 |
| digit **3**          | **R**   | 48 |
| red hangup           | quit    | 114 |

L/R on the digits 1 and 3 is a ruling (the two keys sit left/right on the top
row of the keypad, where shoulder buttons would be). The digit scancodes come
from Task J's keyinject table (`docs/remote.md`); they were checked by
injecting them while the engine ran (`GBA_STATS=1` logs every **unmapped**
scancode as `gba: unmapped key N`, and 51/48 did not show up while 49 did).
The same table (and the hangup key) is used by the Game Boy build, where L/R
do nothing. A per-game keymap editor is Task L.

## The launcher (`lib/retro-boot.sh gba URL`)

1. refuses a non-http(s) URL, or when another game engine is running
   (`cfw_game_running`);
2. downloads with `curl -fkL --max-filesize 32M` to `/tmp/game.gba` (RAM;
   `/tmp` is a 40 MB tmpfs, so 32 MiB is the hard ceiling anyway);
3. checks the header: **byte 0xB2 must be 0x96** (the fixed value every GBA
   cartridge carries and the BIOS checks), so an HTML error page or a GB ROM
   never takes over the screen;
4. stores the URL in `/snom/cfw-data/gba/history` (newest first, 8 max) for
   the phone menu; an unwritable flash only loses the history (logged);
5. touches `/tmp/ssh_fast_update` (rcS must not reboot when lid dies) and runs
   the engine; after it exits, `/snom/cfw/lib/phone-restore.sh` (Task D) brings
   the phone app back, falling back to a reboot.

It reports progress in `/tmp/gba.status` (`downloading`, `error <text>`,
`running`, `done`) and logs to `/tmp/gba.log`. The panel CGI
(`cgi-bin/boot-gba`) and the phone CGI (`cgi-bin/phone-retro`) start the
launcher in the background and poll the status file for up to 20 s / 15 s, so
a bad URL, an unreachable host or a non-ROM file is reported right away
instead of "nothing happens". `boot-gba?log=1` shows the status and the log.

## BIOS

gpSP has a built-in open-source BIOS replacement, used by default. If a real
`gba_bios.bin` is placed in `/snom/cfw/gba/` it is used instead (`gpsp_bios =
auto`); we don't ship one.

## Saves

Battery saves go to `/tmp` (RAM), i.e. they are lost on quit. Persisting them
under `/snom/cfw-data/saves/` is Task K.

## Building

`tools/build-retro.sh` (docker; `CORES="gpsp gambatte"` by default) clones
gpSP at a pinned commit, builds `libcore.a` with
`CFLAGS="-march=armv6 -marm -DROM_BUFFER_SIZE=8 -DSMALL_TRANSLATION_CACHE"`,
compiles the frontend with `-DCORE_GPSP` and links everything statically.
Copy `tools/out/gpsp` to `custom-rootfs/snom/cfw/gba/gpsp`.

- `ROM_BUFFER_SIZE=8`: gpSP keeps up to 8 MB of ROM resident and pages the
  rest from the file in `/tmp`, which keeps the RSS around 14 MB.
- `SMALL_TRANSLATION_CACHE`: smaller dynarec caches, plenty for 120 MB RAM.

## Testing

`tests/retro.sh` deploys and checks the launcher/CGIs (bad URL, unreachable
host, non-ROM file, a hostile URL full of `$()`, backticks, `;` and `../`,
the phone menu). `RETRO_RUN=1 tests/retro.sh` also boots the test ROM end to
end: the launcher downloads it from a throw-away http server on the host,
then the test checks the screenshot (eight colour bars at the expected
positions, black borders), `GBA_STATS` (fps of every 5 s window after start-up
≥ 55), the unmapped-key log, and the `SND_DUMP` PCM with an FFT
(`tests/fftcheck.py`), and quits with an injected hangup key.

The test ROM is `tests/roms/sndtest.gba`, built from `tests/roms/sndtest-gba.S`
by `tests/roms/build.sh` (clang + ld.lld). It draws eight 30-px bars (red,
green, blue, yellow, cyan, magenta, white, grey) in mode 3 and plays a PSG
square arpeggio A4 C♯5 E5 A5 C♯6 A5 E5 C♯5 (one note per 16 frames) on
channel 1 over a constant 220 Hz square on channel 2.

## Measurements

2026-10-30, `tests/roms/sndtest.gba`, `GBA_STATS=1 SND_VOL=5 SND_DUMP=1`,
5 s stats windows, lid/media_daemon killed, lcsD375 stopped:

```
gba: gpSP v1.1.0-5819380 loaded ..., 240x160, audio 32768 Hz
gba: 240x160 -> 408x272 at 36,0
gba: 61.2 fps, queued 1839, underruns 0, blits 296, skipped 2   <- start-up catch-up
gba: 59.6 fps, queued 1724, underruns 0, blits 300, skipped 0
gba: 59.7 fps, queued 1769, underruns 0, blits 300, skipped 0
gba: 59.6 fps, queued 1654, underruns 0, blits 300, skipped 0
gba: 59.7 fps, queued 1699, underruns 0, blits 294, skipped 2   <- screenshot CGI running
```

`top`: gpsp 54 % CPU, 36 % idle, RSS ~14 MB. The FFT of the dump finds the
220 Hz tone in every 100 ms window and all five arpeggio notes within 1 %.
The test ROM is light; real games cost more CPU in the core, and gpSP's
auto-frameskip plus our blit skip absorb that before the audio underruns.

Before the frontend paced from the audio queue (first WIP), the same ROM ran
at 57–60 fps with 4–30 underruns per 5 s.

## Gotchas

- **Load the ROM before `snd_hal_init()`**: the takeover kills lid; anything
  that can fail afterwards strands the user on a black screen until the
  restore/reboot.
- **Pace from the audio queue, not the wall clock.** The codec crystal and the
  CPU clock disagree slightly; wall-clock pacing drifts into a periodic
  underrun click (or a growing latency) every few seconds.
- **gpSP's auto frameskip needs `SET_AUDIO_BUFFER_STATUS_CALLBACK`**; without
  it "auto" never skips.
- **`STATIC_LINKING=1` with other cores** drops libretro-common from the
  archive (RetroArch would provide it); see gb.md. gpSP links fine.
