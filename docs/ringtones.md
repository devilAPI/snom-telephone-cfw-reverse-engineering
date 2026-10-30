# Custom ringtones

Upload your own ringtones in the CFW panel (**Ringtones** card, `/cgi-bin/ringtones`), listen
to them in the browser, assign one to a line, and trigger the stock "Play Ringer" preview.

## How it works (stock mechanism, no binary patch)

The stock firmware already supports a per-identity custom melody:

| setting | meaning |
|---|---|
| `user_customN` | URL of the WAV for identity N (web UI: Identity N, Audio, "Custom Melody URL") |
| `user_ringerN` | `Ringer1`..`Ringer10`, `Silent` or **`Custom`** (plays `user_customN`) |
| `custom_melody_url` | phone-wide setting with the same idea; unused by the CFW |
| `alert_*_ring_sound`, `*_ring_sound` | Alert-Info / contact-group rules; also accept `Custom` |

`state_ringtone.xml` (phone menu Settings, Ringtone) shows a **Custom** entry as soon as
`user_custom[identity]` is set, so after "Use" in the panel the choice is also visible and
selectable on the phone itself.

CFW wiring:

* files: `/snom/cfw-data/ringtones/NAME.wav` (survives reboots; not in the image)
* serving: `/snom/cfw/ringtones` is a **symlink** to that directory (shipped in the image and
  re-created by the CGI if missing). Both busybox httpds serve `/snom/cfw`, and busybox httpd
  follows symlinks out of its home dir (tested), so the file is at
  `http://127.0.0.1:8081/ringtones/NAME.wav` (what the phone uses, loopback = keeps working
  once :8080 has a login) and at `:8080/ringtones/NAME.wav` (browser preview `<audio>`).
* "Use" writes `user_customN=http://127.0.0.1:8081/ringtones/NAME.wav` and
  `user_ringerN=Custom` through the stock web server: `GET http://127.0.0.1/dummy.htm?settings=save&...`
  (values passed with `curl --data-urlencode`, never interpolated). "Back to stock" writes
  `user_ringerN=Ringer1`, `user_customN=` .
* "Play ringer on phone" = the stock web UI button: `GET /line_audio.htm?l=N&PLAY_RINGER:N=Play Ringer`.

## Format

The panel converts **in the browser** (WebAudio `decodeAudioData` + `OfflineAudioContext`):
any format the browser can decode becomes **16 kHz, 16-bit, mono PCM WAV**, cut to the chosen
length (max 32 s), 20 ms fade-out, peak-normalised to -1 dB (optional). Then it is POSTed raw
(`Content-Type: application/octet-stream`, name in the query string), so the CGI needs no
multipart parser and the phone needs no converter (there is no sox/ffmpeg on it).

The CGI re-checks every upload (`rt_check` in `lib/ringtones.sh`, walks the RIFF chunks):
PCM (fmt 1), mono, 16-bit, 8000 or 16000 Hz. Limits: 1 MiB per file (~32 s at 16 kHz),
8 MiB for the whole directory (shared jffs2, ~60 MB free). Names: `[A-Za-z0-9._-]`, ending
in `.wav`, no leading dot, max 64 chars.

Converting on a PC instead: `ffmpeg -i in.mp3 -ac 1 -ar 16000 -sample_fmt s16 -t 30 out.wav`,
then upload `out.wav` (the browser path re-encodes it anyway).

Ruling: 16 kHz is the codec rate of the D375 audio path (`halaudio.apm*` runs at 16 kHz,
docs/sound.md); 8 kHz is accepted too. 44.1 kHz and stereo are rejected server-side because
they were not verified on the phone (the browser never produces them).

## What was verified on the device (and what not)

* lcsD375 **fetched the URL over HTTP** (logged by a test httpd on 127.0.0.1:8099:
  `url:/t16000.wav response:200`) after `user_ringer1=Custom` + `user_custom1=<url>` + Play,
  and the phone's microphone (amxr tap on `halaudio.apm1`, ringer volume 1, 5 % file) picked
  up exactly the file's pattern: 500/1000/1500 Hz tones of 0.4 s repeating every 2.5 s
  (2.0 s file + ~0.5 s pause between repeats). So a 16 kHz PCM WAV over http plays and loops.
* `file://` URLs: no evidence that they work - use http (the CFW does).
* **Caching gotcha (open):** in later runs of the same boot lcsD375 did **not** fetch new
  URLs again (neither on save nor on Play, also not with a fresh file name, also not after
  a reboot that may have lost the not-yet-flushed setting). The melody seems to be loaded
  once and cached; when exactly it is (re)loaded is not established. If a newly chosen
  ringtone does not play, reboot the phone after "Use" (settings must be flushed first,
  see next point), or select Custom again in the phone's Settings, Ringtone menu (which sets
  `var:ringtonereload`).
* **config.xml is flushed lazily:** `dummy.htm?settings=save` applies at once (visible in
  `settings.htm`) but `/snom/snomconfig/config.xml` is rewritten minutes later. Reading the
  current values from config.xml is therefore wrong; the CGI reads the live
  `http://127.0.0.1/settings.htm` and only falls back to config.xml when lcsD375 is down.
  Rebooting right after a save can lose the save.
* `POST line_audio.htm` with `PLAY_RINGER:1=...` is logged as
  `Ignore invalid parameter: PLAY_RINGER:1`; the CGI uses GET.
* **The ringer does not pass through the amxr graph:** an amxr tap on `ept.bind0/1` (the DSP
  output, which carries call audio) records pure zeros while ringing; media_daemon writes the
  ringer straight to the codec. The only capture point is the microphones (acoustic), and
  their path is not always powered on-hook: in some boots the `halaudio.apm*` sources are
  all-zero, then the playback check is inconclusive (the test prints WARN, not FAIL).
* REA/Ghidra could not import lcsD375 (11 MB C++, analysis timed out after 330 s); the
  literal-pool xref approach (strings `user_custom`, `custom_melody_url`,
  `MediaIpc::setRingMelody %s`, `Invalid wave header for file: %s`) found only settings
  tables and the web UI's file-list code, so the format/caching facts above are empirical.

## Failure behaviour

* phone app gone or SIGSTOPped (a game runs): "Use"/"Back to stock"/"Play" answer
  immediately with "phone app is not running (game active?)" - the check is
  `cfw_game_running` + lcsD375 process state (`T`/`Z` in `/proc/PID/stat`), not an HTTP
  probe, because the stock server can take 5-15 s to answer while saving to flash. Stock
  requests carry `curl -m 15`.
* stock web UI protected with `http_user`/`http_pass`: "settings not changed" with the
  HTTP 401 explained (the CFW does not know that password).
* storage full / read-only / short write: upload answers `ERROR could not write ...` and
  removes the partial file; deletes report failure too.
* upload body is never put in a shell variable: the CGI sets `CFW_BODY_READ=1` before
  sourcing `cfw.sh` for `application/octet-stream`, so cfw.sh does not slurp the binary
  body, then `head -c $CONTENT_LENGTH` writes it to a temp file in the data dir.

## Tests: `tests/ringtones.sh`

Deploys the files, uploads 16 kHz and 8 kHz test WAVs (5 % amplitude), checks they are served
on :8080 and on the loopback URL, rejects hostile names (`../x.wav`, `a;b.wav`,
`$(id).wav`, spaces, quotes, `.hidden.wav`, `x.sh`), non-WAV, stereo, 44.1 kHz, oversize and a
hostile `delete`/`line`. Under the phone lock: saves `vol_ringer`/`user_ringer1`/
`user_custom1`, sets ringer volume 1, assigns the ringtone, plays it while `tools/rtcap`
records the microphones, compares spectrograms (`tests/ringtone_corr.py`: right file ~0.37,
other tone pattern ~0.09, noise ~0.03; threshold 0.25), and restores the settings via an EXIT
trap. Then: lcsD375 SIGSTOPped -> clean error within 4 s; a read-only tmpfs over the
ringtone dir -> readable error.

`tools/rtcap.c` (`tools/build-rtcap.sh`): fans any two amxr source ports out to
`amxruser.bind0/1` next to the stock routes, records N seconds, and removes only its own
edges. amxrDisconnect is `_IOR('M',54,8)` = `0x80084d36` (plain `_IO` returns -1 and leaves
the edge in place - the earlier docs/sound.md note was wrong about that).
