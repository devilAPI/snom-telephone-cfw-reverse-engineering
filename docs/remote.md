# Remote screen and keypad

`/cgi-bin/remote` (panel card 55) shows the phone screen live in the browser and lets you press the phone's keys from an on-screen keypad or your keyboard. It works with the normal phone UI and while a game (Doom, NES, ...) owns the screen and keypad.

## Pieces

| Path (under `custom-rootfs/snom/cfw/`) | What |
|---|---|
| `cgi-bin/remote` | the page: canvas + keypad + keyboard shortcuts, plain JS, no libraries |
| `cgi-bin/remote-frame?scale=1\|2\|4` | raw RGB565 frame from `bin/fbshot` |
| `cgi-bin/remote-key?key=NAME[&ms=HOLD]` | presses a key through `bin/keyinject` (whitelist) |
| `bin/fbshot`, `bin/keyinject` | static musl armv6 helpers; sources in `remote-src/`, built by `tools/build-keyinject.sh` (also copied to `tools/out/`) |
| `panel.d/55-remote.html` | panel card |
| `tests/remote.sh` | device test |

All URLs in the page are relative, so with a future Basic-auth login (Task H) the browser re-sends the credentials on every request; nothing in the page needs changing.

## Why these choices

* **Frames are not BMP.** `cgi-bin/screenshot` takes ~0.85 s per 522 KB frame (shell `dd` + `printf` on the ARM1176), i.e. about 1 fps. `fbshot` reads `/dev/fb0` at the visible page (`pan` from sysfs, like the screenshot CGI) and sends RGB565, optionally box-averaged down by 2 or 4: 255 KB / 64 KB / 16 KB. The page expands it to RGBA in JavaScript. Header: `'S' 'F' scale 0 w(u16le) h(u16le)`, then `w*h` little-endian RGB565, top-down. The page polls sequentially (next request only after the previous frame is drawn), so a slow phone never queues requests. It pauses while the tab is hidden.
* **Keys go to evdev, not command.htm.** `command.htm?key=` is served by lcsD375, which is stopped while a game runs. `keyinject` writes `input_event`s (32-bit layout: two int timeval, u16 type, u16 code, int value) to `/dev/input/event0`, the same way `snd_hal.c: inject_speaker` does, so it works in both states. `command.htm` stays as a fallback in `remote-key` only if the helper binary is missing.
* **Whitelist.** `key` must match `[A-Za-z0-9_]{1,16}` and then exactly equal a name in `keyinject -l`; `ms` is digits only, max 3000. Nothing from the request reaches a shell as code, and `keyinject` is called with the name as a plain argument.

## Keypad scancode table (`/dev/input/event0`)

`KEY` capability bitmask of the device (`/sys/class/input/event0/device/capabilities/key`) is `19e007f 7f007f 7f007f 7f0078`, i.e. 52 codes: a matrix scheme `row<<4 | col`: 3-6, 16-22, 32-38, 48-54, 64-70, 80-86, 96-102, 113-116, 119, 120. These are *not* Linux `KEY_*` numbers.

How the table was obtained (nobody could press keys): lid has a name table of the keys it understands (pointer array at file offset 0x80150 of `snom/lid`, `{lid id, name}` pairs: digits are ASCII, `UP` = 107, ...); that is the `Key:` name it reports to lcsD375 as `KEYS DOWN LPCP/1.1 ... Key: <NAME>`. For every code in the bitmask a press was injected into event0 on the running phone while `strace -e send` watched lid, and the `Key:` name that came out was recorded. Status "verified" = observed that way. The codes already known from the games (Up 84, Down 67, Left 101, Right 50) agree with it. Mind that Doom/NES comments call 97 "OK", 115 "Cancel", 116 "Use", 120 "Fire", 114 "Hangup"; the phone's own names for those codes are in the table below.

| name | scancode | command.htm key name | status |
|---|---|---|---|
| 0 | 5 | `0` | verified |
| 1 | 51 | `1` | verified |
| 2 | 49 | `2` | verified |
| 3 | 48 | `3` | verified |
| 4 | 38 | `4` | verified |
| 5 | 37 | `5` | verified |
| 6 | 36 | `6` | verified |
| 7 | 22 | `7` | verified |
| 8 | 21 | `8` | verified |
| 9 | 20 | `9` | verified |
| * (star) | 6 | `*` | verified |
| # (pound) | 4 | `#` | verified |
| Mute | 3 | `MUTE` | verified |
| Volume - | 16 | `VOLUME_DOWN` | verified |
| Speaker | 17 | `SPEAKER` | verified (snd_hal inject, sound.md); not re-injected here since it opens a call |
| Headset | 18 | `HEADSET` | verified |
| Menu | 19 | `MENU` | verified |
| Recall | 32 | `RECALL` | verified |
| Phone book | 33 | `PHONE_BOOK` | verified |
| Transfer | 34 | `TRANSFER` | verified |
| DND | 35 | `DND` | verified |
| Retrieve | 52 | `RETRIEVE` | verified |
| Rec / messages | 53 | `REC` | verified |
| Snom | 54 | `SNOM` | verified |
| Help | 64 | `HELP` | verified |
| Settings | 65 | `SETTINGS` | verified (also screen change, tests/remote.sh) |
| Redial | 66 | `REDIAL` | verified |
| Down | 67 | `DOWN` | verified |
| Up | 84 | `UP` | verified |
| Left | 101 | `LEFT` | verified |
| Right | 50 | `RIGHT` | verified |
| Conference | 96 | `CONFERENCE` | verified |
| Cancel | 97 | `CANCEL` | verified |
| Enter / OK | 120 | `ENTER` | verified |
| F1 | 116 | `F1` | verified |
| F2 | 115 | `F2` | verified |
| F3 | 114 | `F3` | verified |
| F4 | 113 | `F4` | verified |
| Volume + | 119 | `VOLUME_UP` | verified |
| Line key P1 | 99 | `P1` | verified |
| P2 | 86 | `P2` | verified |
| P3 | 83 | `P3` | verified |
| P4 | 81 | `P4` | verified |
| P5 | 70 | `P5` | verified |
| P6 | 68 | `P6` | verified |
| P7 | 100 | `P7` | verified |
| P8 | 98 | `P8` | verified |
| P9 | 85 | `P9` | verified |
| P10 | 82 | `P10` | verified |
| P11 | 80 | `P11` | verified |
| P12 | 69 | `P12` | verified |
| (none) | 102 | - | in the bitmask, but lid reports no key: unmapped |

Not in the table: `HEADSET_HOOK_KEY` (lid id 123) and the hook switch have no code in the bitmask.

Notes for other tasks (games, keymap editor): digit 1 = 51 and digit 3 = 48; Volume - / + = 16 / 119. Key names printed in the phone's own terms: what Doom calls "Hangup" (114) is the phone's F3, "Cancel" (115) is F2, "Use" (116) is F1, "Fire" (120) is the ENTER key, and "OK" (97) is CANCEL. Games keep their own labels; this only names the physical keys.

## Using it

* `keyinject UP`, `keyinject -d 500 ENTER` (hold ms), `keyinject -c 51` (raw code), `keyinject -l` (name table). Names are case-insensitive; `STAR` and `POUND` alias `*` and `#`.
* Keyboard shortcuts on the page: arrows, Enter (OK), Esc and Delete (Cancel), 0-9, `*`, `#`, F1-F4, `+`/`-` (volume), S speaker, M mute, H headset.
* The status line shows frames per second, KB per frame and ms per frame. Quality selector: 120x68 / 240x136 / 480x272.

## Gotchas

* `media_daemon` holds an exclusive grab of event0, but writes from another process are still delivered to its reader; only reading event0 needs the grab removed (see `doom.md`).
* Key injection while a call is active acts like the real key (Speaker, Redial and the P-keys can dial or answer). Treat the remote like a hand on the phone.
* A press is 60 ms down, 40 ms gap. A game that polls slower than that can miss a tap; use `ms=` for longer presses (the page does not expose it).
* The probe that built the table was run with the phone idle (no registered call). `102` produces no key name; it might be a hook-like contact.
* Frame rate depends on the phone CPU being shared with the running UI; see the numbers measured by `tests/remote.sh` in the task report.
