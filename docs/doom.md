# DOOM on the snom D375

The **Boot Doom** button in the [CFW Settings](cfw-settings.md) panel runs DOOM
(Freedoom Phase 2) natively on the phone's own screen and keypad. Engine:
[doomgeneric](https://github.com/ozkl/doomgeneric) with a small snom platform
layer; built static against musl (same reasoning as [nano](building-nano.md)).

## Hardware the port uses (reverse-engineered on the device)

| | |
|---|---|
| Display | `/dev/fb0`, **480x272, 32bpp**, stride 1920. Doom renders 320x200 and is **centered** (no scaling) with a black border. |
| Input | `/dev/input/event0` ("keypad"). **Not** usable until the app releases it (see below). |
| Keypad codes | Up=84 Down=67 Left=101 Right=50 OK=97 Fire=120 Use=116 Cancel=115 **Hangup=114** |

Controls → Doom: arrows = move/turn, Fire = shoot, Use = open doors, OK = menu
select, Cancel = menu/back, **red Hangup = quit Doom**.

## Two things that make the takeover work

1. **Stopping the UI without a reboot.** When the phone app (`lid`) exits, rcS's
   `startUpApplication` loop normally reboots. Creating **`/tmp/ssh_fast_update`**
   (rcS's `ffupdatefile`) makes that loop *wait* instead, and relaunch the app
   when the file is removed. The launcher uses this to hold the phone while Doom
   runs.
2. **Freeing the keypad.** `event0` is held with an **exclusive grab by
   `media_daemon`** (not just by `lid`). Until `media_daemon` is killed, *nothing*
   reads the keys — this is why early evdev and `/dev/keypad*` captures were all
   empty. The launcher kills both `lid` and `media_daemon`.

`media_daemon` does not cleanly restart by hand, so **quitting Doom reboots the
phone** to restore everything (UI + call audio). ~2 min; clean and reliable.

## Pieces

| Path | In image? | What |
|---|---|---|
| `snom/cfw/doom/doom` | yes | the engine (static musl armv6, ~420 KB) |
| `snom/cfw/doom/boot-doom.sh` | yes | launcher: hold rcS, kill `lid`+`media_daemon`, run Doom, reboot |
| `snom/cfw/cgi-bin/boot-doom` | yes | CGI the button posts to; detaches the launcher with `nohup` |
| `snom/cfw/index.html` | yes | has the **Boot Doom** button |
| `/snom/doom/freedoom2.wad` | **no** | the IWAD — pushed separately (see below) |

## The WAD is downloaded from a URL (nothing stored)

The Boot Doom button prompts for a **URL to a WAD**. The launcher downloads it to
`/tmp` (RAM), runs Doom, and deletes it on quit — no WAD is kept on the phone or
in the image. (A Freedoom IWAD is ~29 MB; the phone's `/tmp` is 40 MB, so one WAD
fits with room to spare.) The download happens **before** the screen takeover, so
a bad URL just reports an error and leaves the phone usable.

**The WAD's filename matters.** Doom (chocolate-doom lineage) picks the game —
Doom 1 vs Doom 2, Freedoom Phase 1 vs 2 — from the IWAD *filename*. Saved under a
generic name like `doom.wad` it assumes Doom 1 and rejects a Doom 2 IWAD
(`W_GetNumForName: d_introa not found`, exit 255). So the launcher
(`/snom/cfw/doom/boot-doom.sh`) URL-decodes and lowercases the URL's basename
and keeps it if it is a known IWAD name (`doom2.wad`, `freedoom2.wad`,
`plutonia.wad`, …). Otherwise it detects the game from the lumps (`MAP01` →
`doom2.wad`, `E1M1` → `doom.wad`).

**Accepted links** (all tested on-device 2026-10-29):

| Link | What the launcher does |
|------|------------------------|
| direct `.../DOOM2.WAD` (any host) | downloads it |
| `archive.org/details/<item>/<file>` | rewrites to `/download/` (a `/details/` link is an HTML viewer page; this was why archive.org links "didn't load") |
| `archive.org/details/<item>` or `/download/<item>` | reads `archive.org/metadata/<item>/files` and picks a known IWAD name, else any `.wad`, else a `.zip` |
| `archive.org/download/<item>/<file>.zip` | the phone has no `unzip`, so it uses archive.org's server-side zip view (`<zip>/<member>`) and picks the IWAD inside |
| `.zip` from other hosts | rejected (no unzip) |

PWADs (add-on map packs) and HTML pages are rejected with a clear message.
Every step and error goes to `/tmp/doom.log`, which the CFW page shows at
**`/cgi-bin/doom-log`** (linked from the "Downloading…" page, auto-refreshes).

## Building the engine

`tools/build-doom.sh` cross-builds it in a container (needs `docker`):
doomgeneric sources + `doomgeneric/doomgeneric_snom.c` (the fb/evdev/keymap
layer), `-DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200`, static musl
`-march=armv4t`. Output `tools/out/doom` → copy to
`custom-rootfs/snom/cfw/doom/doom` (root:0755). It is under `/snom`, so the
first-boot `cleanUpRootfs` pass does not touch it (unlike `/usr/bin/nano`).

## Known limitations

- **No sound** (deferred; the phone's audio path is a separate effort).
- The phone can't take calls while Doom runs; quitting reboots it.
- The keypad number keys (weapon select) are unmapped — only nav + fire/use/menu.
