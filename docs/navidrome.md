# Navidrome player

The phone plays music from a [Navidrome](https://www.navidrome.org) server, or any other
Subsonic-compatible server, on its loudspeaker. You browse on the phone itself, and the
phone app keeps running. It is built on the [network speaker](speaker.md): the player is
one more sender to it.

Status: works on the D375 (2026-11-04), tested against a throwaway Navidrome 0.64 in
docker (`tests/navidrome.sh`). How it sounds with real music is on
[to-test.md](../to-test.md).

## Set up

1. In the web panel, tab Phone, card **Navidrome**, open "Server settings".
2. Address: the server's **http://** address in your LAN, for example
   `http://192.168.1.10:4533`. HTTPS doesn't work: the phone's busybox wget has no TLS.
   If the server is only reachable through an HTTPS reverse proxy, use its LAN port.
3. User and password, then "Save and test". The card answers "saved, the server answers"
   or the server's error (for example "Wrong username or password").

The password is not stored. The phone keeps a random salt and `md5(password + salt)`,
which is how the Subsonic API logs in (`u`, `t`, `s` parameters). Anyone who reads the
config file (root only, mode 600) can use that token with the API, but can't recover the
password from it. The config is `/snom/cfw-data/navidrome/conf`, outside the firmware
image.

**On the server** nothing needs to change. The phone asks for each track as
`format=mp3` at the chosen bit rate (64, 96 or 128 kbit/s; 96 is the default). Navidrome
converts with its built-in "mp3" transcoding, which needs ffmpeg on the server; the
official Docker image has it. With another Subsonic server, make sure it can transcode
to MP3.

## Use it

**Phone:** Menu, CFW Tools, **Navidrome**:

| Item | What it does |
|---|---|
| Playing: title - artist | while something plays: position, track n of m (select to refresh) |
| Pause / Resume, Next track, Previous track, Stop | the controls |
| Random songs | 50 random songs |
| Artists | all artists, 20 per page, then an artist's albums ("Play all" plays up to 15 albums) |
| Albums: newest / random / recently played / most played | Navidrome's album lists |
| Playlists | your playlists, "Play all" or from a track |
| Search | text input on the keypad; the results list artists, albums and songs |
| Output: speaker / handset | where the sound goes, shared with the speaker ([speaker.md](speaker.md), the handset is experimental) |
| Volume up / down | in steps of 10, saved |

Choosing a track in an album or playlist plays from there to the end of the list.
"Previous track" goes to the start of the current track if it has played more than 5 s.

**Panel:** the same card shows what plays, the controls, a volume slider, "Random songs"
and a search with Play buttons for albums and songs.

**Keys:** `/snom/cfw/scripts-examples/navidrome-toggle.sh`, `-next.sh`, `-prev.sh` and
`-stop.sh` call the player. Copy them to `/snom/cfw-data/scripts/` and put them on keys
([scripts.md](scripts.md), [keymap.md](keymap.md)).

**Together with the PC:** `tools/snom-speaker.sh` streams into the speaker's "live"
channel and the player uses the "player" channel. Both play at the same time, mixed. A
PC that streams silence doesn't interrupt the music.

## How it works

```
Navidrome --(HTTP, MP3)--> busybox wget --(pipe)--> navplay --(HTTP POST, WAV)--> spkstream --> loudspeaker
                                                    libmad, mono,                "player" channel
                                                    22.05 kHz
```

| File | Role |
|---|---|
| `navidrome-src/navplay.c` | MP3 from stdin, decoded, sent to spkstream. Built by `tools/build-navplay.sh` |
| `custom-rootfs/snom/cfw/navidrome/player.sh` | The player: queue, the track loop, next / prev / pause / resume / stop / volume / status |
| `custom-rootfs/snom/cfw/navidrome/nd-lib.sh` | Config, the Subsonic API call, XML parsing, request parsing, menu rendering |
| `custom-rootfs/snom/cfw/cgi-bin/navidrome` | Phone menus (`a=phone`, loopback :8081) and the panel's JSON |
| `custom-rootfs/snom/cfw/panel.d/92-navidrome.html` | Panel card |
| `custom-rootfs/snom/cfw/phone-menu.d/32-navidrome` | Entry in CFW Tools |
| `custom-rootfs/snom/cfw/scripts-examples/navidrome-*.sh` | Scripts for keys |
| `tests/navidrome.sh` | The test with a throwaway server |

### Decoding: navplay

The ARM1176 in the D375 has a VFP unit, but the kernel doesn't enable it (`/proc/cpuinfo`
lists no `vfp`), and the userland is soft-float. A floating-point decoder would be far
too slow, so navplay uses **libmad** 0.15.1b (GPL-2), a fixed-point decoder with ARM
multiply-accumulate assembly (`FPM_ARM`). The build script compiles its source files
directly, with a small fixed `config.h`, without its old configure script.

`MAD_OPTION_HALFSAMPLERATE` makes libmad synthesise at half rate (22.05 kHz from a
44.1 kHz MP3), and navplay averages the two channels. The speaker path is 16 kHz mono
anyway. Measured: 30 s of 96 kbit/s MP3 decode in 1.5 s of CPU, about 5 % of the CPU.

navplay connects to spkstream on 127.0.0.1:8091 and POSTs a WAV header (the decoded rate,
mono, no length) followed by the samples; spkstream resamples to 16 kHz. When
spkstream's 2 s buffer is full, TCP slows navplay down, which slows wget down.

Exit codes: 0 played to the end (spkstream answered `played`), 2 stopped or replaced
(another sound in the player channel, or `/stop`), 1 an error (no MP3 data, the speaker
isn't reachable). `-P FILE` writes the seconds decoded so far, once a second.

### The player

`player.sh start N` plays `/tmp/navidrome/queue` from track N. The queue has one line
per track: `id TAB title TAB artist TAB duration TAB album`. The CGI writes it from
`getAlbum`, `getPlaylist`, `getRandomSongs`, `search3` or `getArtist` + `getAlbum`.

A background loop (`player.sh loop`) plays one track after another: it calls `scrobble`
with `submission=false` (now playing), then `wget stream.view | navplay`, and when the
track has played to the end, `scrobble` with `submission=true`. So plays show up in
Navidrome's "recently played" and play counts. Three failed tracks in a row stop the
loop with an error.

- **Pause** stores the position and stops. The position is the seconds navplay decoded
  plus the start offset, minus what spkstream still holds (`buffered_ms` of the player
  channel).
- **Resume** starts the same track again with Navidrome's `timeOffset` (it seeks in its
  ffmpeg transcoding). That's why the player always asks for MP3, even when the original
  is already MP3.
- **Next, prev, stop** stop the loop and its navplay and tell spkstream
  `/stop?ch=player`, so the 2 s still in the buffer don't play on.

Only one loop may run. `halt` clears `loop.pid` before it kills the loop, and every loop
checks that `loop.pid` still holds its own pid before it changes the state or starts a
track. An earlier version let an exiting loop delete the new loop's pid file. That gave
two loops playing at once after "next", each replacing the other's sound.

### Speed

The phone's CPU is busy: the phone app takes about 35 % and the load is around 6.
Starting a process costs about 100 ms. The first version of the CGI took 5 to 10 s per
menu, nearly all of it in forks: about 5 per `cfw_param`, 2 per escaped menu item, a
`sed` per config key, and a walk through `/proc` with one `readlink` per process to find
navplay. Now:

- `nd_params` parses the whole request (POST body and query) in one awk call, which
  also URL-decodes. The output is read with `while IFS=TAB read`, so nothing is evaluated.
- `nd_menu` turns "name TAB url" lines into the whole escaped `IPPhoneMenu` in one awk
  call.
- `nd_load` reads the config with `read`, and `nd_status` reads the player state with
  `read` plus one awk call for the queue line.
- `pidof navplay` instead of walking `/proc`; `speaker.sh` only when the receiver isn't
  running.

Measured on the phone: views 0.5 to 1.2 s, actions (play, next, pause) 1.4 to 4.4 s,
depending on how busy the phone app is.

### busybox quirks found on the way

- `od` has no `-A` or `-t`, so `nd_urlenc` uses `od -b` (octal) and turns the bytes into
  `%XX` in awk.
- busybox awk reads `line (x)` as a call of a function named `line`, even with the space.
  Write `sep = ...; line = line sep x`.
- busybox wget handles Navidrome's chunked transfer encoding, so navplay can just read
  stdin.

## Gotchas

- "the server does not answer": wrong address, HTTPS, or the phone can't reach the
  server. Check with "Save and test" in the panel.
- "nothing to play": the list was empty, or the server didn't answer.
- A track fails at once ("track n failed" in the log): the server couldn't transcode it
  to MP3. Is ffmpeg installed there?
- The player and the panel's "Play file" share the player channel; the last one wins.
- Games stop the phone's audio service, so they stop the music too.
- Log: `/tmp/navidrome/log`, also in the panel's Logs tab as "Navidrome player".

## Test

`tests/navidrome.sh` needs docker, ffmpeg and curl on the PC. It starts Navidrome in docker
with generated tones, points the phone at it and checks:
- the setup errors (HTTPS, wrong password), and that the password is not stored and the
  config is mode 600;
- the menus with `&` and `<…>` in names, search on the phone and in the panel, and
  hostile input;
- play, position, the speaker channel, next, pause (nothing decoding), resume at the
  paused position, prev, stop (no navplay left) and the end of the queue.

It saves the phone's own config first and puts it back at the end.
