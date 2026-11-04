# Network speaker / reverse intercom

The other direction of the [intercom](intercom.md): sound from a browser or a PC plays
on the D375's loudspeaker. The phone app keeps running the whole time; nothing is taken
over. The intercom and the speaker can run at the same time, so the two together make a
two-way link.

Status: works on the D375 (2026-11-04). Checked by playing test sounds and recording
them with the phone's own microphone, see [Test](#test). How it sounds to a person is
still on [to-test.md](../to-test.md).

## Use it

**Panel**, tab Phone, card "Speaker / reverse intercom":

* Start / Stop the receiver.
* Volume 0 to 100. The default is 30, because the speaker is loud.
* Play file: the browser decodes the file (anything it can play: mp3, ogg, m4a, wav),
  mixes it to mono at 16 kHz and sends it to the phone. "Stop sound" stops it.

**Phone**, Menu, CFW Tools, "Speaker (play from PC)": start, stop, and see whether
something is playing.

**Linux PC**: `tools/snom-speaker.sh` adds a sound output called "snom D375":

```sh
tools/snom-speaker.sh 192.168.178.72          # asks for the panel password
tools/snom-speaker.sh -d 192.168.178.72       # also make it the default output
tools/snom-speaker.sh -v 50 -f song.mp3       # play one file (needs ffmpeg)
CFW_AUTH=root:PASSWORD tools/snom-speaker.sh  # no password prompt
```

The script starts the receiver on the phone through the panel if it is off. Then pick
"snom D375" as the output in the sound settings or in pavucontrol, or move one app to it.
Ctrl-C removes the output again and puts the old default back. `-s` also stops the
receiver on the phone. If the connection breaks (the phone rebooted, WiFi dropped), the
script reconnects every 2 seconds.

It needs `curl`, `pactl`, and `parec` (pulseaudio-utils, also works with pipewire-pulse)
or `pw-record`. It runs on PulseAudio and on PipeWire. Tested on PipeWire 1.6.

**Anything else** can send to the receiver over HTTP:

```sh
TOKEN=...   # from the panel: /cgi-bin/speaker?a=status&fmt=txt
curl --data-binary @sound.wav "http://PHONE:8091/play?k=$TOKEN"
ffmpeg -i radio-url -f s16le -ac 1 -ar 16000 - | curl -T - -H Expect: "http://PHONE:8091/play?k=$TOKEN&live=1"
```

## HTTP interface (port 8091)

Every request needs `k=TOKEN`, otherwise the answer is 403. The token is new on every
start. It is shown to whoever can open the panel, and stored in `/tmp/speaker/token`.

| Request | What it does |
|---|---|
| `POST` or `PUT /play?k=T` | Plays the body. Takes a WAV file (16-bit PCM, any rate, mono or stereo) or raw S16LE, 16000 Hz mono by default, or `rate=` and `ch=1\|2`. The length can come from `Content-Length` or chunked encoding, or the body runs until the sender closes. Answers when the sound has played: `played N ms`. A new `/play` replaces the one playing; the old one is answered with `stopped`. |
| `&vol=0..100` | Volume for this and later sounds. |
| `&live=1` | For endless streams (a PC's sound output). An adaptive buffer that keeps the delay low (see below). |
| `GET /stop?k=T[&ch=player\|live]` | Stops the sound, in one channel or in both. |
| `GET /vol?k=T&v=N[&ch=player\|live]` | Sets the volume, also while something plays. Without `ch`: the default for both. |
| `GET /status?k=T` | `{"playing", "buffered_ms", "keep_ms", "underruns", "dropped_ms", "missed_frames", "max_gap_ms", "vol", "sessions", "player": {...}, "live": {...}}`. The top level covers both channels; `player` and `live` each have `playing`, `buffered_ms`, `underruns`, `dropped_ms` and `vol`. `missed_frames` counts frames the frame clock skipped; `max_gap_ms` should stay at 5. |

**Two channels, mixed.** `live=1` senders (the PC script) play in the "live" channel,
everything else (files, the panel, the [Navidrome player](navidrome.md)) in the
"player" channel. A new `/play` replaces only the session in its own channel, and the two
channels are added together, with clipping. Without this the PC script, which is always
connected and reconnects within 2 s, cut off the Navidrome player 2 s after every start.

The answers carry `Access-Control-Allow-Origin: *`, so the panel on port 8080 can send
files. It sends them as `text/plain`, which keeps them simple requests without a CORS
preflight.

Panel CGI: `/cgi-bin/speaker?a=status|start|stop[&v=VOL]&fmt=json|txt`, and
`?a=phone[&do=start|stop]` for the phone menu. Every parameter is checked against a
fixed list; only the volume digits reach a command.

## How it works

Files:

| File | Role |
|---|---|
| `intercom-src/spkstream.c` | The receiver: HTTP, decoding, ring buffer, frame pump, gain control. Built by `tools/build-intercom.sh` |
| `custom-rootfs/snom/cfw/intercom/speaker.sh` | `start [VOL]`, `stop`, `status` |
| `custom-rootfs/snom/cfw/intercom/amxr-mod.sh` | Loads and unloads `amxr_user_hook.ko`, shared with the intercom |
| `custom-rootfs/snom/cfw/cgi-bin/speaker` | Panel and phone menu CGI |
| `custom-rootfs/snom/cfw/panel.d/91-speaker.html` | Panel card |
| `custom-rootfs/snom/cfw/phone-menu.d/31-speaker` | Phone menu entry |
| `tools/snom-speaker.sh` | The PC side |

### The path to the loudspeaker

The phone has no ALSA (see [sound.md](sound.md)). Its audio is the Broadcom amxr mixer:
the codec `halaudio.apm1` (APM channel 1, the speakerphone, 16 kHz mono) receives from
`ept.bind1`, the phone app's voice DSP. amxr adds up every source connected to one
destination, so a second source plays along with the phone's own sound.

spkstream loads nothing itself. `speaker.sh` loads the stock `amxr_user_hook.ko`
(`/dev/amxruser`, ports `amxruser.bind0..2`), then spkstream:

1. connects `amxruser.bind0 -> halaudio.apm1`, the sound path, and
   `halaudio.apm1 -> amxruser.bind0`, which is never read. The module only signals frames
   while some connection leads *into* one of its ports. Without this second connection
   the pump waited forever, unless the intercom happened to run.
2. Every 5 ms frame: waits for the frame (`ioctl 0xc0044502`), takes 80 samples from the
   ring buffer, applies the volume and writes them (`ioctl 0xc0044500`, `{int port; void
   *buf}`, 160 bytes) to port 0. It writes zeros when there is nothing to play. The
   module repeats the last frame if nothing new is written, so a frame is written every
   time.
3. While the intercom runs, micstream owns the frame clock and spkstream hands its frames
   through `/tmp/amxr-play.fifo`. The module wakes only one process per frame. See
   [intercom.md](intercom.md#together-with-the-speaker-spkstream).

### Unmuting

On an idle phone every codec gain reads -1000 (muted), the speaker output too. A tone
written to `apm1` was silent until two blocks were set, measured with the phone's
microphone:

| Block | Range | Role | Set to |
|---|---|---|---|
| `0x109` | -50..18 dB, 1 dB steps | CH1 digital output gain | +1 dB |
| `0x121` | -21..0 dB, 3 dB steps | CH1 analog output stage, also powers the amplifier | 0 dB |

With only `0x109` there was nothing; with both the tone was 275 times above the room
noise. spkstream sets them when sound starts (gain ioctls from
[intercom.md](intercom.md): `0x80084132` get, `0x80084133` set), but only on blocks that
read -1000. It checks again once a second while sound plays, because the phone mutes
again after a call. After 2 seconds of silence it puts -1000 back, but only if `0x109`
still reads +1. That value marks the unmute as spkstream's: if the phone app has set the
gains for a call or a ring in the meantime, they are left alone. A frame counts as silent
when no sample is above 4 after the volume, so a PC that streams silence doesn't keep the
amplifier on.

During a call the phone app owns the gains. The stream still plays into the
speakerphone, mixed with the call. The caller does not hear it.

### Real-time priority (the fix for cracks and skips)

The first version cracked and skipped with music. The user's first session showed
17 underruns and 4.2 s dropped in about 6 minutes, on a phone with load 8.9 where the
phone app takes up to 35 % CPU. The cause was the pump being late.
The module wakes a waiter only if it already waits when the frame comes (see
[intercom.md](intercom.md#together-with-the-speaker-spkstream)). A pump that is late
misses the frame: the module plays the last frame again (a crack) and the missed
frame's audio piles up in the buffer, which was then trimmed (a skip).

The pump thread now runs with `SCHED_FIFO` priority 40, and micstream does the same,
since it owns the clock while the intercom runs. Measured with 40 s of loud test music
streamed live (`spkstream -N` turns the priority off, for exactly this comparison):

| | missed frames | longest gap between frames |
|---|---|---|
| normal priority | 28 | 10 ms |
| `SCHED_FIFO` 40 | 0 | 5 ms |

A real-time thread that spins would freeze the phone. Both pumps count their wakes and
sleep 4 ms per wake once there are more than 300 in a second (200 is normal).

### Buffering and delay

The ring buffer holds 2 s. A file is sent as fast as TCP allows. When the buffer is
full, spkstream stops reading, so the sender is slowed down to the playback speed.

A live stream from a PC runs on the PC's clock, which is a little faster or slower than
the phone's 16 kHz, and WiFi delivers in bursts. For `live=1`:

* It keeps 150 ms buffered and starts playing at 250 ms.
* Every underrun raises the kept level by 50 ms, up to 600 ms, so a bad WiFi link gets
  a longer delay instead of repeated dropouts. It starts at 150 ms again for every new
  stream.
* Every 2 seconds it compares the lowest level it saw with the kept level. Whatever was
  buffered the whole time is surplus delay. It is played away 1.25 % faster: 81 samples
  are resampled into 80, which isn't audible. Only a surplus over 1 s is skipped at once.

Measured with the PC script: about 110 to 210 ms buffered, no underruns. History: the
first version dropped whenever more than 300 ms were buffered, which cut out half the
audio because of the WiFi bursts. The second trimmed the surplus in one jump every
2 seconds, which you hear as a skip.

The PC script doesn't use curl for live streaming: curl reads 64 kB (2 s) of a pipe
before it sends. It opens the TCP connection with bash's `/dev/tcp`, sends a request
header without a length and then the raw output of `parec`.

### Resampling

WAV files and `rate=` other than 16000 Hz are resampled linearly, and stereo is
averaged to mono. That is fine for speech and announcements. For music, let the sender
convert, as the panel (an OfflineAudioContext at 16 kHz), the PC script (PipeWire or
PulseAudio resample into the 16 kHz output) and the ffmpeg example do.

## Security

* The receiver port 8091 is not behind the panel login. It needs the per-start
  random token (96 bit); without it the answer is 403.
* Anyone with the token can play sounds on the phone. HTTP, not HTTPS: someone who sniffs
  the LAN can see the token.
* At most 8 connections at once, 5 s to send the request header, and a live sender that
  sends nothing for 10 s is dropped.
* The receiver never starts by itself: everything lives in `/tmp/speaker/` and is gone
  after a reboot.

## Gotchas

* Don't `kill -9` spkstream: its amxr connections would stay. `speaker.sh stop` falls back
  to `spkstream -x` for that case.
* Like the intercom, it refuses to start while a game runs. Games take over the audio
  hardware. Stop the speaker before playing.
* `pkill -f snom-speaker` in a shell whose own command line contains that text kills
  the shell too. Use the PID.
* "frame clock stopped for N ms" in the log: no frame came at all for that long. Seen
  for up to 6 s exactly when the phone app (`lid`, `media_daemon`) was restarted, for
  example by a game or the Rockbox test. These stops also count in `missed_frames`.
* The phone's wall clock jumps (seen: back 6 h, then forward again). The 2 s mute timer
  uses `CLOCK_MONOTONIC`; an earlier version used `time()`.
* `missed_frames` grows: the pump has no real-time priority (look for "no real-time
  priority" in `/tmp/speaker/log`) or something else runs at a higher priority.
* `speaker.sh` and `intercom.sh` recognise their daemon by `/proc/PID/exe`. After the
  binary was replaced that link reads `.../spkstream (deleted)`, and an earlier version
  then didn't stop the old daemon.
* Status says `buffered_ms` 2048 and nothing plays: no frame clock. Look for the
  `halaudio.apm1 -> amxruser.bind0` connection in `/proc/amxr`.

## Test

`tests/speaker.sh` (needs the phone and takes the shared phone lock):
* the panel card and the phone menu render, and hostile CGI input is ignored;
* 403 without a token;
* a 1 kHz tone at about 5 % amplitude plays and is found in a recording by the intercom
  (the FFT peak at 1 kHz is more than 20 times the median);
* a 2 s sound takes about 2 s;
* the intercom keeps its full frame rate while the speaker runs;
* after stop the module, the amxr connections and the port are gone, and the gains read
  -1000.
