# Intercom / baby monitor

Stream the D375's microphone to a PC or a browser over the LAN, **while the phone
UI keeps running** (no takeover, no reboot, calls still work).

> **Privacy:** while the intercom is on, the phone's microphone is live for anyone
> on the LAN who has the stream link (it carries a random token). The phone has no
> LED we can drive, so the only on-phone indicator is the
> *Settings -> CFW Tools -> Intercom* screen ("Intercom: ON - mic is live"). It is
> **off after every reboot** and only starts when you start it.

## Using it

| Where | How |
|---|---|
| Web panel (`http://<phone>:8080/`) | card *Intercom / baby monitor*: pick a gain, **Start**, the `<audio>` player plays the stream. **Stop** turns the mic off. |
| On the phone | *Settings -> CFW Tools -> Intercom*: *Start intercom* / *Stop intercom*, current level. |
| PC | `tools/intercom-listen.sh [PHONE_IP]` (starts it if needed, plays via ffplay/aplay/paplay). `-r file.wav -t 60` records a minute, `-s` stops the intercom on exit, `-u user:pass` for the panel login. |
| Anything that plays HTTP audio | `http://<phone>:8090/stream.wav?k=<token>` (VLC, ffplay, mpv, a browser). Raw S16LE without header: `/raw?k=<token>`. |
| Shell on the phone | `/snom/cfw/intercom/intercom.sh start [GAIN] | stop | status` |

The token is shown by the panel card, by `cgi-bin/intercom?a=status&fmt=txt` and in
`/tmp/intercom/token` on the phone. It changes on every start. Up to 4 listeners at once.

Format: 16 kHz, mono, signed 16-bit little endian, i.e. 32 kB/s (256 kbit/s). The WAV
header says "length 0xFFFFFFFF" (endless), which browsers, ffplay, aplay and VLC accept.
Latency is about 20 ms on the phone plus whatever the player buffers (ffplay with
`-fflags nobuffer`: well under a second; browsers: 1-3 s).

Gain (`g`, 0..6) is a digital left shift with saturation: 0 = x1 ... 6 = x64. The raw
mic level in a quiet room is small; 2 (x4, default) is a good start for a nursery,
use 4-5 to hear a quiet room from far away (more hiss).

## Files

| File | Purpose |
|---|---|
| `intercom-src/micstream.c` | the capture + HTTP server (static musl, integer only) |
| `tools/build-intercom.sh` | docker cross-build -> `tools/out/micstream` + `custom-rootfs/snom/cfw/intercom/micstream` |
| `custom-rootfs/snom/cfw/intercom/intercom.sh` | start/stop/status: insmod, token, start-stop-daemon, cleanup |
| `custom-rootfs/snom/cfw/cgi-bin/intercom` | CGI for the panel (json), PC tool (txt), phone menu (minibrowser XML), HTML fallback |
| `custom-rootfs/snom/cfw/panel.d/90-intercom.html` | panel card with the `<audio>` element |
| `custom-rootfs/snom/cfw/phone-menu.d/30-intercom` | CFW Tools menu entry |
| `tools/intercom-listen.sh` | PC side |
| `tests/intercom.sh` | end-to-end test |

## How it works

### The capture tap (amxr_user_hook)

The audio routing on the D375 is Broadcom's *amxr* mixer (see `docs/sound.md`). At
idle the graph is `halaudio.apm{0,1} <-> ept.bind{0,1}` (codec <-> voice DSP), 16 kHz
mono, 5 ms frames. The stock firmware ships, but never loads,
`/lib/modules/2.6.27.47/BROADCOM/amxr_user_hook.ko` (it is part of the image, listed in
`rootfs_files.lst`; nothing extra to ship). Loaded, it registers two amxr ports
`amxruser.bind0/1` and the char device `/dev/amxruser` (major 236; the node already
exists in `/dev`, `intercom.sh` `mknod`s it if not).

`micstream` then:

1. `amxrQueryPortByName` (`ioctl(/dev/amxr, 0x80244d30, {char name[32]; void **out})`)
   for `halaudio.apm0`, `halaudio.apm1` and `amxruser.bind2`;
2. `amxrConnect` (`0x800c4d35`, `{src, dst, desc = 0x1010}`) for both APM channels:
   *additional* connections. amxr fans a source out to several destinations, so the
   phone's own `apm* -> ept.bind*` stays untouched and calls keep working. **bind2**, not bind0/1:
   other test tools (audio/ringtone experiments) connect `ept.bind* -> amxruser.bind0/1`,
   and amxr *mixes* every source connected to one destination, so sharing a port would
   mix their signal into the mic stream;
3. loops `ioctl(/dev/amxruser, 0xc0044502)` (blocks until the next 5 ms frame sync)
   and `ioctl(0xc0044501, {int port = 2; void *buf})` (copies one 80-sample, 160-byte frame);
4. on SIGTERM: `amxrDisconnect` (`0x80084d36`, `{src, dst}`, recovered from
   `libamxr.so`), re-mute (below), exit. `intercom.sh stop` then `rmmod`s the module,
   but only if *it* loaded it and no other connection to `amxruser.*` exists.

**DC blocker.** The freshly unmuted ADC delivers an offset of about +900 LSB (≈ +3700
at x4 gain) on top of the room noise. micstream runs a one-pole high-pass
(`y = x - x1 + 0.995 y1`, Q15 integer, corner ≈ 13 Hz) before the gain, so the stream
is centred on 0 (the test checks |mean| < 300).

Single-threaded: after every 4 frames (20 ms) the batch goes to every listener with a
non-blocking `send`; a listener whose 64 kB socket buffer is full (too slow, or gone)
is dropped instead of stalling the capture. New connections and their HTTP request are
handled between batches.

### Why the mic is silent at idle, and the fix (the "open question")

Right after boot, with the phone idle, a capture gives **exact digital zeros** on both
`halaudio.apm0` and `apm1` - not noise, zeros. The capture path itself works (600
frames in 3 s), so something mutes the samples before amxr sees them.

Dumping the halaudio gain blocks (`halAudioGetGainInfo`, `ioctl(/dev/halaudio,
0x80084132, {int block; int *info})`, `info[0]` = current dB, `info[1..2]` = range;
**the kernel writes a whole table, give it >= 1 kB or it smashes the stack**) showed
it. Block ids are `(cid << 8) | type`; media_daemon's "mute everything" routine calls
`halAudioSetGain` (`0x80084133`, `{block, db}`) for `4, 8, 9, 0x10, 0x11, 0x104,
0x108, 0x110, 0x120, ...` with one value:

| type | range | meaning (inferred) |
|---|---|---|
| `0x04` | -50..0 dB | **sidetone** (mic looped back into the speaker). Earlier micstream versions unmuted this by mistake |
| `0x08` | -50..18 dB | **digital mic gain** (APM reg `0x40`/`0x70`). While it is muted the ADC delivers exact zeros |
| `0x09` | -50..18 dB | the other digital stage (APM reg `0x2c`/`0x5c`), not needed for capture |
| `0x10`, `0x20` | 0..42 dB, 3 dB steps | analog preamp of mic input A / B (one shared PGA). Writing either also switches the channel's input mux (`ApmHW_SetTxMux`) to that input; muting either powers the PGA down |
| `0x11`, `0x21` | -21..0 dB | analog output stage |

Observed values (cid 0 = APM CH0, cid 1 = CH1; "forced" = what micstream sets):

| state | `0x004` | `0x010`/`0x020` | `0x104` | `0x110`/`0x120` | capture |
|---|---|---|---|---|---|
| fresh boot, idle | -1000 | -1000 | -1000 | 24 | zeros on both channels |
| fresh boot, CH0 forced 0 / 24 dB | 0 | 24 | | | CH0 still zeros |
| fresh boot, CH1 ADC forced 0 dB | | | 0 | 24 | **CH1 live** (room noise) |
| off-hook (dial tone) | -20 | 18 | -1000 | -1000 | CH0: the 425 Hz dial tone, rms ~300 |
| idle after speaker/call use | -20 | 18 | -1000 | -1000 | CH1 ADC forced: still zeros; CH0 forced: room noise |

So **which APM channel carries a live microphone depends on the last route
media_daemon set up** (it powers the analog input of the transducer it used last;
the ADC gain alone does not wake a powered-down input). Ruling: micstream connects
**both** `halaudio.apm0` and `apm1` to `amxruser.bind2`. amxr sums all sources of one
destination, so the dead channel adds exact zeros and the live one comes through,
in every state, without touching media_daemon's routing (`-c 0`/`-c 1` select one).

`micstream` opens `/dev/halaudio` as a second client (no superuser, no power change,
no codec lock) and, for each tapped channel, blocks `(ch << 8) | 0x04` (ADC, set to 0 dB, `-A`) and
`| 0x10`, `| 0x20` (preamps, 24 dB, `-P`), sets every block that reads -1000. It
re-checks once a second, because media_daemon re-mutes after every call. On exit it
puts -1000 back on the blocks it changed, but only if they still hold its value (if a
call is active media_daemon owns them). Blocks that are not muted are left alone.
`micstream -x` (used by `intercom.sh stop` after a `kill -9`) only removes the amxr
connections: after a crash we can't tell our gain values from media_daemon's, and an
unmuted ADC on an idle phone is harmless (media_daemon resets it on the next call).

### Which microphone (2026-10-30)

Decoded from `halaudio.ko` (`halAudioSetGain`: bit 3 = digital gain, bit 2 = sidetone, otherwise analog with
`(type >> 4)` = input and `type & 3` = stage) and `halaudio_apm.ko` (`apmAnaGainSet` calls `ApmHw_PGAGainSet`,
`ApmHw_AmpSetPowerDown` and `ApmHW_SetTxMux`), then verified on the phone by reading the APM registers through
`/dev/mem` at physical `0x30600000` (kernel virtual `0xf3600000`).

I measured the room-noise rms of each input at a 24 dB preamp and a 0 dB digital gain:

| `micstream` | APM channel / input | rms | microphone |
|---|---|---|---|
| `-c 0 -m 0` | CH0 / A (`0x010`) | 17 | handset |
| `-c 0 -m 1` | CH0 / B (`0x020`) | 2 | headset jack (empty) |
| `-c 1 -m 0` | CH1 / A (`0x110`) | 4 | unused |
| `-c 1 -m 1` | CH1 / B (`0x120`) | 40 | speakerphone (base), the input media_daemon uses in speaker mode |

`intercom.sh start GAIN MIC` maps `speaker` (default), `handset`, `headset` and `both` (`-c 2 -m 2`) to these. The panel
card and the phone menu offer the choice. Switching while running restarts micstream, which gives a new token, and the
panel player follows. micstream re-points the input mux once a second while the phone is idle, and never during a call.

### During a call

The tap keeps running. During a call media_daemon sets the ADC gain itself, so the
stream carries the call's microphone signal (the local side of the conversation).
After the call it mutes again and micstream unmutes within a second. If that is not
wanted, stop the intercom before calling.

### Coexistence with games

`intercom.sh start` refuses while a CFW game/emulator runs (they kill media_daemon and
take the audio hardware) and when media_daemon is not running: the CGI answers at once
with `error=...`. A game started while the intercom runs is not blocked; the tap keeps
streaming whatever the APM ADC delivers. Stop the intercom before playing.

## Security

* The stream port 8090 is separate from the panel and is **not** behind the panel
  login. It is protected by the per-start random token (96 bit from `/dev/urandom`):
  without `k=<token>` it answers 403. Anyone who can read the panel (or `/tmp/intercom/token`
  on the phone) can listen. HTTP, not HTTPS: someone sniffing the LAN can hear it too.
* CGI parameters are whitelisted (`a`, `fmt`, `do` from fixed lists, `g` a single digit);
  nothing else reaches a command. The micstream HTTP parser only accepts `GET` with a
  path of at most 255 bytes and a header of at most 1 kB, and closes idle connections
  after 5 s.

## Gotchas

* **Exact zeros = muted, not broken.** If a capture is all zeros, check
  the gain blocks `0x004`/`0x010`/`0x020` (or look at `level=` in `intercom.sh status`,
  "rms peak" of the last second). micstream logs which blocks it unmuted in `/tmp/intercom/log`.
* `start-stop-daemon -b` gives micstream `/dev/null` as stdio; it logs to
  `/tmp/intercom/log` via `-l`.
* Don't `kill -9` micstream: the amxr connection would stay and `rmmod` may refuse.
  `intercom.sh stop` falls back to `micstream -x` for exactly that case.
* `pkill -f micstream` over ssh matches the ssh shell itself (see `docs/cfw-dev.md`);
  use `intercom.sh stop`.
* Everything lives in `/tmp/intercom/` and is gone after a reboot: the intercom never
  auto-starts.

## Test

`tests/intercom.sh` (needs the phone, takes the shared phone lock for the deploy and
the stream part): panel card and phone menu render; hostile CGI input
(`;reboot`, `$(...)`, newline, `../`, `"><script>`) is neither executed nor reflected;
start via the CGI; no token -> 403; 5 s of `stream.wav` is a valid 16 kHz mono
16-bit WAV with ambient energy (rms > 2, > 50 distinct values); a second listener
(`/raw`) works at the same time; lid / media_daemon / lcsD375 PIDs are unchanged;
stop removes the module, the amxr tap and the port; a second stop is harmless.
