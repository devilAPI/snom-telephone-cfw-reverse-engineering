# Zipped games (NES, GB/GBC, GBA, Doom)

Every launcher accepts a `.zip` URL as well as a bare ROM/WAD. The launcher
downloads it to `/tmp`, unpacks it, finds the game file and runs it.

## Rules
* **Detection by content**: the download is a zip if it starts with `PK\003\004`. The URL (`.zip` or not) is never used.
* **Extensions** (case-insensitive, subfolders searched): NES `.nes`; GB launcher `.gb` and `.gbc` (one Gambatte engine, one launcher, `boot-gb`); GBA `.gba`; Doom `.wad`. `__MACOSX/` entries and `._*` files are ignored.
* **0 matches**: error `no .nes file inside the zip` in the launcher log (`/tmp/<sys>.log`), the web panel reply and the phone screen. Nothing is started.
* **1 match**: it is moved to the normal path (`/tmp/game.nes`, ...) and runs exactly as if it had been downloaded bare.
* **Several matches**: the launcher stops with status `choose <sid> <n>`. The web panel shows one button per file; the phone shows an `IPPhoneMenu`. Choosing starts that file. The unpacked files stay in `/tmp/zip-<sys>/` (RAM) until one is chosen or a new download of that system replaces them. Choosing never re-downloads. On the phone, Settings -> Games -> `<system>` also gets "Choose file from last zip..." while a choice is pending.

## Untrusted input
`sid` and the file number come from the browser/phone. `lib/zip.sh:zip_pick` accepts only digits (and `-` in the sid), requires the sid to equal the stored `/tmp/zip-<sys>/sid`, requires `1 <= n <= lines(list)`, and takes the path from its own list file by line number. The client never supplies a path; nothing is eval'ed. `busybox unzip` also refuses `../` and absolute entry names (tested in `tests/zip.sh`).

## The unzip tool
The phone's busybox has no `unzip` applet (`busybox --list`). `tools/build-unzip.sh` builds busybox 1.36.1 with only the unzip applet, static musl armv6 (150 KB), shipped as `/snom/cfw/bin/unzip` (`-l` listing, `-qo ... -d dir -x pattern`; it has no usage text, `unzip -h` just says "unrecognized option"). Only deflate/stored are supported (no bzip2/lzma/xz, no encryption).

## RAM
`/tmp` is a 40 MB RAM disk. `zip_extract` reads the unpacked total from `unzip -l`, refuses with a clear message if it exceeds free space, and deletes the zip as soon as it is unpacked. A 32 MB GBA ROM zipped to 20 MB therefore cannot be unpacked in place; link the bare ROM then.

## Saves
Saves are keyed by the ROM's SHA-1 (NES/GB/GBA) or IWAD name (Doom), see saves.md. The extracted ROM is moved to the usual path first, so a ROM from a zip has the same key as the same ROM downloaded bare. Doom uses the entry's base name (lowercased) as IWAD name, with the usual lump-based fallback.

## Doom and archive.org
Unchanged: `archive.org/download/<item>/x.zip` is still resolved server-side (`<zip>/<member>`, saves RAM). Any other zip is now unpacked on the phone instead of being rejected.

## Files
`lib/zip.sh` (shared functions), `lib/retro-boot.sh`, `nes/boot-nes.sh`, `doom/boot-doom.sh` (`--pick SID IDX` second step; status in `/tmp/<sys>.status`), `cgi-bin/boot-gba` (one CGI for all four systems; `boot-gb/nes/doom` are wrappers), `cgi-bin/phone-pick`, `phone-boot`, `phone-retro`, `phone-games`.

## Test
`tests/zip.sh` (~6 min, host serves zips on 192.168.178.49:8000 - the host firewall lets the phone reach only 8000/8080): list/extract checks for every system, hostile parameters, no-match, broken and malicious zips, then three real runs (multi-ROM NES via the phone menu with choice 2, nested single GB ROM, plain NES ROM).
