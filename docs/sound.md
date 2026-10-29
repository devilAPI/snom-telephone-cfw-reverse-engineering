# Sound on the snom D375 — audio architecture & status

**Status: working. Doom and NES play clean audio on the loudspeaker.**
We get PCM out of the loudspeaker from a takeover app while still owning the
keypad, and a full game-audio pipeline (decode → mix → resample → stream) is
implemented for Doom and NES. The long-standing "noise" problem was **not** the
telephony DSP: the kernel's `/dev/halaudio` write path byte-swapped our samples
because we passed `fmt = 0` (S16BE) instead of `fmt = 1` (S16LE). See
**"The voice DSP blocker was a byte-order bug"** below.

This file records how the phone's audio actually works (reverse-engineered on the
device). It's deep because the phone has **no usable ALSA/OSS** — audio is a
proprietary Broadcom telephony stack.

## TL;DR of the hardware

The D375 is a **Broadcom BCMRING** phone. Audio is **not** ALSA/OSS:

- `/dev/snd/*` and `/dev/dsp` exist but are **vestigial** — every PCM open returns
  `ENXIO`. There is no `/proc/asound`, no `/sys/class/sound`. `libasound.so.2` is
  present but useless here. tinyalsa 2.0 can't open the card either (version
  mismatch with the 2.6.27-era core). **Do not go down the ALSA/OSS road.**
- Real audio is three Broadcom char devices, driven only by the closed
  `media_daemon`:
  | node | major | role |
  |---|---|---|
  | `/dev/halaudio` | 233 | codec control (power, route, freq, gain, PCM read/write) |
  | `/dev/amxr`     | 213 | "Audio Mixer/Router" — the PCM routing graph |
  | `/dev/ept0`     | 221 | telephony endpoint = the Broadcom voice **DSP** |
- Kernel modules: `halaudio.ko`, `amxr.ko`, `amxr_user_hook.ko`, and the APM/PCM/I2S
  interface drivers under `drivers/char/broadcom/halaudio_drivers/`.

## Live state (phone idle, on-hook)

`cat /proc/halaudio`:

```
Interfaces: APM id=0 codecs=2 frame_period=5000 enabled=1 ; PCM id=1 enabled=1 ; USB id=2 enabled=0
Codecs:     APM CH0 cid=0 ; APM CH1 cid=1 ; PCM CH0 cid=2 ; USB cid=3
Clients:    media_daemon powerlevel=2
```

`cat /proc/amxr` (the routing graph):

```
halaudio.apm0 <-> ept.bind0     (16000 Hz, 1ch, fs=160)   active
halaudio.apm1 <-> ept.bind1     (16000 Hz, 1ch, fs=160)   active
halaudio.pcm0 <-> ept.bind_nb0  ( 8000 Hz, 1ch, fs=80)    active
halaudio.usb                    (no connections)
```

So the physical codec (`halaudio.apm*`, **16 kHz mono**) is wired to the EPT DSP
(`ept.bind*`), and **the EPT gates which transducer is live** (earpiece vs. the
hands-free loudspeaker) and powers its amplifier. The APM clock runs even when
idle, which is why injecting a tone at the APM is **inaudible on-hook** — the
analog output stage is powered down until the EPT selects a device.

### Hardware sine generators (useful for testing)

`/proc/sys/bcmapm/sine_freq0` and `sine_freq1` inject a tone at APM ch0/ch1
(`echo 1000 > sine_freq0`). Also `loop*` (loopback) and `ramp_*` test switches.
**Confirmed inaudible while on-hook** — needs the EPT to enable a device first.

## The two ways in (both recovered on-device)

### 1. `libhalaudio.so` — direct codec API (unstripped!)

The phone ships an **unstripped** `/lib/libhalaudio.so`. Its functions are thin
ioctl shims over `/dev/halaudio`; the ABI was recovered by disassembly
(`llvm-objdump -d`). ioctl magic = `'A'` (0x41):

| function | ioctl | notes |
|---|---|---|
| `halAudioAllocateClient` | — | `open("/dev/halaudio", O_RDWR)` → fd is the handle |
| `halAudioSetSuperUser`   | `_IO('A',57)` | arg passed directly |
| `halAudioQueryCodecByName`| `_IOR('A',67,36)` | struct `{char name[32]; int;}` |
| `halAudioQueryInterfaceByName`| `_IOR('A',66,36)` | same shape |
| `halAudioEnableInterface`| `_IOR('A',65,8)` | `{int iface; int enable;}` |
| `halAudioSetFreq`        | `_IOR('A',58,8)` | `{int codec; int hz;}` |
| `halAudioSetGain`        | `_IOR('A',51,8)` | |
| `halAudioSetPower`       | `_IO('A',53)`  | level (idle=2) |
| `halAudioWrite`          | `_IOR('A',56,8)` then `write(fd,buf,n)` | sig `(fd,a1,a2,buf,n)` |
| `halAudioRead`           | `_IOR('A',55,8)` then `read(fd,buf,n)`  | |
| `halAudioLockCodec`/`Unlock` | `_IO('A',48/49)` | |

`libamxr.so` (also unstripped) exposes routing: `amxrAllocateClient`
(`open("/dev/amxr")`), `amxrConnect` = `_IOR('M',53,12)`, `amxrQueryPortByName`,
`amxrDisconnect`, etc. (magic `'M'`).

Because these are plain ioctls, they can be **replicated directly from the
static-musl game binaries** — no glibc linking, no new toolchain, no helper.

### 2. `pxcon` console on `127.0.0.1:1299`

`media_daemon` embeds the Broadcom **`pxcon`** debug console and **listens on TCP
`127.0.0.1:1299`** (the UI `lcsD375` is on 1298). It drives the EPT exactly like
the phone firmware does. Relevant commands:

- `start` — start EPT in a default mode (auto-run by most commands)
- `eptSetDevice handsfree` — select the hands-free loudspeaker (powers its amp)
- `ss 0 <sig> on <ms>` — generate a signal: `dtmf1..`, call-progress, ring, or
  `custom_tone1..16`
- `mcon <srcport> <dstport> mono` / `mdisc` — amxr mixer connect/disconnect
- `halac`, `halsuper`, `mixerac`, `lock` — client/handle management
- `sd <dev> rxgain <dB>`, `ecmute hf <on/off>`

EPT devices/ports seen: `ept_handset`, `ept_headset`, `ept_spkrphone`,
`halaudio_spkrphone_mixp`, `ept_spkrphone_mixp`. Audio modes:
`audio_mode_handset`, `audio_mode_handsfree`, `audio_mode_handsfree_loud`,
`audio_mode_headset`, `audio_mode_bt_headset`.

## Plan to get game sound

1. **Prove output** (next step): over `:1299`, `start` + `eptSetDevice handsfree`
   + `ss 0 custom_tone1 on 3000` (or drive `sine_freq0` once a device is enabled).
   Confirm a tone from the loudspeaker.
2. **Bring up the loudspeaker route** for a takeover app: reproduce the minimal
   `pxcon`/EPT sequence that enables handsfree + amp.
3. **Stream PCM:** `halAudioWrite` 16 kHz mono S16 frames (5 ms = 80 samples) to
   the APM codec, after resampling the engine's audio (Doom 11025/22050,
   NES ~44100) down to 16 kHz mono.
4. **Wire into engines:** `doomgeneric` `I_SubmitSound`/`I_UpdateSound` and
   InfoNES `InfoNES_SoundOutput` push resampled frames into the HAL writer.

### Input vs. audio coexistence — SOLVED

The keypad (`/dev/input/event0`) is held with an exclusive `EVIOCGRAB` by
`media_daemon`, and the hands-free route/amp is also managed by `media_daemon`.
The working sequence (implemented in `snd/snd_hal.c`), done **while
`media_daemon` is still alive**:

1. `open("/dev/halaudio")`, `SetSuperUser(1)`, `SetPower(2=FULL)`,
   `EnableInterface(APM,1)`, `SetFreq(cid1,16000)` — we become a second codec
   client **holding FULL power**.
2. Inject a **SPEAKER keypress (evdev code 17)** into `/dev/input/event0` so
   `media_daemon` runs its own EPT hands-free bring-up (loudspeaker amp ON).
3. `kill -9` lid + `media_daemon` (with `/tmp/ssh_fast_update` held so rcS
   doesn't reboot). Because we still hold FULL power, the APM interface / amp /
   DMA stay up and `halAudioWrite` keeps draining; the EPT route is frozen in
   hands-free (kill -9, no cleanup). The keypad is now ungrabbed and ours.
4. A pump thread streams 16 kHz mono S16 via `halAudioWrite` to `cid1`.

Proven on-device: a 440 Hz tone via this path is **audible on the loudspeaker
with `media_daemon` dead** (keypad simultaneously readable). The codec consumes
at exactly 16 kHz (timed: 166000 samples ≈ 10.4 s of blocking writes).

### The "voice DSP" blocker was a byte-order bug — SOLVED (2026-10-29)

Symptom (from earlier sessions): pure tones played pitched, but broadband game
audio came out as level-proportional noise. This was blamed on the EPT
hands-free AEC/NLP and chased through amxr reroutes, pxcon, `/etc/*_ecregs` and
EC-register binary patches. **All of that was a red herring.**

Root cause, found by reverse-engineering the kernel: the `/dev/halaudio` char
device layer (`halaudio_read/write/ioctl`) is **built into the kernel**, not in
`halaudio.ko`. Extracted the gzip'd Image from `boot/uImage` (10.1.64.17),
located the fops table via the `__func__` string literals (`halaudio_write` @
`0xc0197624`, `halaudio_read` @ `0xc0197798`, `halaudio_ioctl` @ `0xc0197124`,
load base `0xc0008000`) and disassembled `halaudio_write`. It looks at the
`fmt` stored by the `_IOR('A',56,8) {cid, fmt}` ioctl:

| `fmt` | kernel behaviour |
|-------|------------------|
| 1     | native **S16LE**, passed straight to `halAudioWrite(..., 1, ...)` |
| 2, 3  | 8-bit companded, expanded to 16-bit through a lookup table |
| anything else (**incl. 0**) | treated as **S16BE**: the kernel byte-swaps every sample (loop @ `0xc0197734`), then writes |

`snd_hal` sent little-endian samples with `fmt = 0`, so every sample was
byte-swapped. A byte swap is a fixed nonlinear map: a periodic tone stays
periodic (harsh but pitched), broadband audio turns into full-scale noise. The
fix is one constant: `fmt = 1` (`HAL_FMT_S16LE` in `snd/snd_hal.c`). No
media_daemon patch, no EC tuning, no serial console needed. The stock
`media_daemon` is used unchanged.

**Objective verification (no listening required).** Kernel `halAudioRead` only
works for codecs with a read op, and APM has none (`halAudioRead` → `-EINVAL`).
Instead, capture via the stock but normally unloaded `amxr_user_hook.ko`
(`insmod` it; char dev major 236 = `/dev/amxruser`):

- Route mic: `amxrQueryPortByName` `_IOR('M',48,36)` for `halaudio.apm1` and
  `amxruser.bind1`, then `amxrConnect` `0x800c4d35` `{src, dst, desc=0x1010}`
  (`0x1010` = the mono→mono descriptor media_daemon itself uses).
- Loop: `ioctl(u, 0xc0044502)` waits for the frame sync, then
  `ioctl(u, 0xc0044501, &{port, buf})` copies one 160-byte (5 ms, 80-sample)
  frame. (`0xc0044500` is the SRC direction: inject 160 B into an amxr port.)

Played a 5 %-amplitude feed (440 Hz sine, 200–5000 Hz log sweep, 7-tone chord)
and fitted a 96-tap linear FIR from source to capture on the PC:

| write fmt | sine | sweep | chord | capture RMS (chord) |
|-----------|------|-------|-------|---------------------|
| 0 (old)   | 8 %  | 25 %  | 4 %   | ~2000 (noise)       |
| 1 (fixed) | 98 % | 98 %  | 99 %  | ~160                |

(fraction of captured energy explained by a linear filter of the source). With
`fmt = 1` the path is linear, and the user confirmed by ear that game sound is
clean. Test tool source: `tools/halloop.c` (see its header for usage).

The old EC/pxcon notes below are kept for reference only; they are **not**
needed for game audio.

<details><summary>Historical EC/pxcon investigation (not needed)</summary>


The speaker key puts the EPT into `audio_mode_handsfree` — a **call** mode with
AEC + residual-echo suppressor + noise-suppressor + AGC + comfort-noise active.
That DSP is nonlinear and speech-tuned: a pure sine passes (we hear a clean
tone), but broadband game audio is turned into level-proportional noise. Verified
by capturing exactly what the pump sends (`SND_DUMP=1` in `snd_hal.c`) and
confirming the captured PCM is **correct Doom audio on a PC**, while the same PCM
on the phone is noise. So the digital pipeline is correct end-to-end; only the
analog/DSP stage mangles it.

`media_daemon`'s strings list `audio_mode_handsfree_noaec`, `audio_mode_ringer`
(ringtones play complex audio cleanly to the loudspeaker), and EC registers with
`CNG_OFF`/suppressor bits — any of these would give clean playback, but they are
only reachable through the **`pxcon` console on the serial UART** (media_daemon
`fd4 = /dev/ttyAMA0`; it listens on **no** TCP port) or through the EPT ioctl ABI
in a lib we haven't pulled (`/dev/ept0`). Next avenues to try:

- **`amxr` reroute — TRIED, did not help.** Disconnected both
  `ept.bind1 → halaudio.apm1` and `halaudio.apm1 → ept.bind1` (both ioctls
  returned 0). A test tone **stayed audible** afterwards — so `halAudioWrite`
  feeds the apm1 DAC directly, *not* via the EPT amxr path — but broadband audio
  was **still noise**. Conclusion: the mangling is the EPT/APM hardware DSP
  still running media_daemon's last hands-free-call config, bound at the codec
  level, independent of the amxr graph. amxr can't reach it. (ABI recovered:
  `amxrQueryPortByName` = `_IOR('M',48,36)` `{char name[32]; PORT* out}` — the
  "port id" is a kernel pointer; `amxrDisconnect` = `_IO('M',54)` `{src,dst}`;
  `amxrConnect` = `_IOWR('M',53,12)`; client = `open("/dev/amxr")`.)
- **Serial-console access is the clean unlock.** `media_daemon` embeds the
  `pxcon` console on the UART (`console=ttyAMA0,115200n8`, kernel cmdline). Over
  that console these commands fix it directly (device alias `hf` = handsfree):
  `ecenable hf disable`, `ecnlp hf disable`, `eccng hf off` (kill the AEC / non-
  linear residual suppressor / comfort-noise), or select `audio_mode_handsfree_noaec`.
  The EC device map, confirmed live: **devId 0 = handset (hec, 17 regs), devId 1
  = headset (hec), devId 2 = speakerphone (sbaec, 932 regs)** — the speakerphone
  AEC (devId 2 / `hf`) is what mangles our audio. Needs a USB-UART adapter on the
  phone's serial header. **This is the recommended fix.**
- Raw `/dev/ept0` VRG messages: the EPT driver (`ept_driver.ko`/`ept_core.ko`,
  major 221) is a message-queue API (`endpoint_ioctl` + `DoSetDevice` etc.)
  running Broadcom's PhoneXChange VRG stack, statically linked into the
  **stripped** 1.9 MB `media_daemon` (no separate libept, no symbols). Replicating
  the EC-disable / audio-mode provisioning message would mean reconstructing the
  VRG message protocol from the stripped binary — days of RE, and the EPT may
  reject commands from a non-owner. Not attempted to completion.
- Running `media_daemon` as a second `pxcon` instance does **not** work as a
  shortcut: with the real daemon alive a second instance exits immediately
  (resource conflict); with it dead the instance re-inits its own EPT but does
  **not** read piped stdin as commands. `TIOCSTI` into `/dev/ttyAMA0` /
  `/dev/console` (media_daemon's fd4/fd0) injects fine as root but the running
  app-mode daemon doesn't run the interactive pxcon command reader, so nothing
  processes it. **Confirmed: pxcon command I/O is the serial UART console only**
  — every network-reachable runtime path was tried and fails.
- **Startup EC-register override file (best non-serial lead, untested).** At EPT
  startup media_daemon tries to load per-device tuned EC registers from
  `/etc/handset_ecregs`, `/etc/headset_ecregs`, **`/etc/spkrphone_ecregs`**
  ("Opened file %s containing tuned EC registers for devId=%d"). These files do
  **not** exist (built-in defaults are used). Creating `/etc/spkrphone_ecregs`
  (devId 2) with the residual/noise suppressor + AGC registers set to pass-
  through should give clean speakerphone audio, persistent across reboot, no
  serial. Blocker: the file format (parsed by `ecRegLineToIdxValPairs`, name/
  value pairs set via `EPTPARM_EC_REGS`) and the exact sbAEC register
  values/indices can only be obtained by dumping them with pxcon
  (`ecgetregsdef 2 <file>` / `ecgetregsdiff`) — which needs the serial console.
  Writing the file blind risks breaking EC init. So this too currently needs one
  serial session (to capture a known-good dump as a template), after which the
  override file alone would suffice on every boot.


</details>

Also note: the injected-SPEAKER bring-up (step 2) is **racy** — it sometimes
fails to bring the amp up (total silence). A manual speaker press is reliable.
Needs a readiness check or retry.

## Current status / what works

- **Implemented** (`snd/snd_hal.{c,h}`): codec arming, hands-free bring-up via
  injected speaker key, `media_daemon` takeover, a pthread pump + SPSC ring, and
  a linear resampler. Shared by both games (plain C, `extern "C"` for the NES
  C++ build). `SND_DUMP=1` dumps the exact PCM sent to `/tmp/snd_dump.raw`.
- **Doom** (`doom-src/doomgeneric/i_snom_sound.c`): a full SFX `I_*`
  implementation replacing doomgeneric's stub `i_sound.o` — DMX lump decode
  (8-bit → 16-bit at half scale), per-tic software mixing of up to 16 channels
  to 16 kHz mono, pushed to `snd_hal`. Music (MUS/MIDI) is stubbed.
- **NES** (`nes-src/InfoNES_System_snom.cpp`): `InfoNES_SoundOutput` mixes the 5
  APU channels, DC-blocks and gains them, and pushes at the APU rate (44100 Hz)
  through `snd_hal`'s resampler.
- Both engines call `snd_hal_init()` first in `main()` (before fb/keypad), and
  the boot scripts no longer kill `media_daemon` (the engine's `snd_hal_init`
  does, after arming audio).
- **Works end to end**: clean game audio on the loudspeaker since the
  `fmt = 1` fix (verified by mic capture and by ear, 2026-10-29).
- Test tools (scratchpad, not committed): `halplay`/`halplay2` (tone + auto
  hands-free), `halfeed` (stream a raw S16/16k file; `NOINJECT=1` for a manual
  speaker press), `snd_selftest` (sine through the ring/pump path).

## Transfer notes (dev environment)

- Phone SSH has **no SFTP** — `scp` fails; push/pull with
  `ssh root@phone "cat > /tmp/x"` / `base64` over ssh (binaries: base64 both ways).
- Multi-line `cat` of `/proc/{amxr,halaudio}` truncates over the ssh pipe; copy to
  a `/tmp` file on the device first, then `base64` it back.
