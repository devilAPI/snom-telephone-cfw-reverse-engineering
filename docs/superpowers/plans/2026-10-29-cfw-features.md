# D375 CFW Feature Wave Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add twelve user-facing features to the snom D375 custom firmware (CFW): on-phone Scripts menu, idle-screen widgets, custom boot splash and theme icons, persistent game saves, quitting games without a reboot, GB/GBC and GBA emulators, a per-game keymap editor, custom ringtones, a mic intercom/baby monitor, a password login for the panel, a system-info page and a remote screen+keypad page.

**Architecture:** Everything lives under `custom-rootfs/` (shipped in the signed image) plus native sources built by `tools/build-*.sh` (docker, static musl, armv6 soft-float). Web features are busybox-httpd shell CGIs in `custom-rootfs/snom/cfw/cgi-bin/`. On-phone features are minibrowser XML (IPPhoneMenu/IPPhoneText/IPPhoneInput) served by the same CGIs on a loopback-only, auth-free httpd. To let tasks run in parallel without colliding, Task 0 creates **drop-in directories** for panel cards and phone-menu entries, a shared shell library and a test library. Every later task adds its own files instead of editing shared ones.

**Tech Stack:** busybox sh/httpd (ash, no bash in CGIs), minibrowser XML, C (musl static, `arm-linux-musleabi`), libretro cores (gpSP, a GB core), Python 3 for host-side tools, ssh to the live phone.

**Spec:** the user's feature list (2026-10-29, conversation), quoted in each task's "Spec" line. There is no separate spec document, so rulings made against it are provisional.

## Global Constraints

- Phone: `192.168.178.72`, root password `snom375`. Non-interactive ssh needs `SSH_ASKPASS` and `-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa`. Use `tests/lib.sh` (Task 0).
- **The phone is shared with other agents and sessions.** Anything disruptive (killing lid/media_daemon, game takeover, reboot, playing audio, remounting rootfs, restarting httpd) MUST run inside `flock /tmp/claude-1000/snom-phone.lock …`. Read-only ssh and curl GETs need no lock. Hold the lock for the shortest time possible.
- Audio tests play at **5% amplitude** (`SND_VOL=5` or scale samples ×0.05); the speaker is very loud.
- **Only the controller builds the firmware `.bin`** and edits `custom-firmware/`, `custom-rootfs/etc/checksum.md5`, `README.md` and `docs/cfw-settings.md`. Tasks never touch those files; they list any needed checksum or README notes in their report.
- **Ownership:** tasks must not edit `custom-rootfs/snom/cfw/index.html`, `state_settings.xml` (except Task 0) or any other task's files. Panel UI goes in `custom-rootfs/snom/cfw/panel.d/NN-<name>.html` and phone-menu entries in `custom-rootfs/snom/cfw/phone-menu.d/NN-<name>` (see Task 0).
- Persistent runtime data goes in `/snom/cfw-data/<feature>/`. It survives reboot (and is not in the image). Tasks must check on the device whether `/` needs `mount -o remount,rw /` to write there, and use `cfw_rw`/`cfw_ro` from `cfw.sh` if so.
- Shell CGIs: busybox ash, `#!/bin/sh`, mode 0755, `Content-type` header first. Untrusted input is never `eval`ed or interpolated into shell commands unquoted. HTML output escapes `& < > "`.
- Native code: static musl armv6 (`-march=armv6 -marm`), no FPU (integer or fixed-point math in hot paths), stripped. Prebuilt binaries are committed to both `tools/out/` and their `custom-rootfs/` location.
- A new file under `bin lib sbin usr` must be added to `custom-rootfs/etc/rootfs_files.lst`. Prefer `/snom/cfw/…` for everything.
- Every task adds or updates `docs/<feature>.md` (heavy docs: the user wants the why and the gotchas recorded).
- Commit messages are prefixed `CFW:` and end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A URL, filename or script name containing spaces, quotes, `;`, `$()` or `../` passed to any CGI must neither break out into the shell nor escape its directory. Each task with a CGI gets a hostile-input test.
2. Running a feature while a game owns the screen (lid/media_daemon dead) must fail cleanly, not hang a CGI.
3. A full or read-only flash (`/snom/cfw-data` not writable) must give a readable error, not a silent loss.
4. After the password login lands, the on-phone menus (Games, Scripts, etc.) must still work, because they use the auth-free loopback port. Task H's test checks every `phone-menu.d` URL.
5. After "quit without reboot", a second game launch and an incoming call must still work. Task D tests a relaunch and that SIP registration comes back.

---

### Task 0: Shared foundation (sequential, before all others)

**Files:**
- Create: `custom-rootfs/snom/cfw/lib/cfw.sh`, `custom-rootfs/snom/cfw/cgi-bin/panel`, `custom-rootfs/snom/cfw/cgi-bin/phone-tools`, `custom-rootfs/snom/cfw/panel.d/` (move the existing index.html cards into `10-reset-pw.html`, `20-reset-ssh.html`, `30-doom.html`, `40-nes.html`, `50-screenshot.html`), `custom-rootfs/snom/cfw/phone-menu.d/`, `tests/lib.sh`, `tests/foundation.sh`, `docs/cfw-dev.md`
- Modify: `custom-rootfs/snom/cfw/index.html` (becomes `<meta http-equiv="refresh" content="0; url=/cgi-bin/panel">`), `custom-rootfs/snom/html/xml/gui/state_settings.xml` (one new `<Menu name="CFW Tools" id="cfw_tools">` whose Url is `http://127.0.0.1:8081/cgi-bin/phone-tools`; repoint Games to `:8081`), `custom-rootfs/etc/init.d/rcS` (start a second `busybox httpd -p 127.0.0.1:8081 -h /snom/cfw` next to the :8080 one)

**Interfaces (produces):**
- `cfw.sh` (source with `. /snom/cfw/lib/cfw.sh`):
  - `cfw_param NAME`: prints the url-decoded value of NAME from `$QUERY_STRING`, or from the POST body for POST (read once and cached in `$CFW_BODY`)
  - `cfw_html_escape` (stdin to stdout), `cfw_xml_escape` (stdin to stdout)
  - `cfw_html_head TITLE` / `cfw_html_foot`: panel page chrome (the same CSS as today's index.html)
  - `cfw_phone_text TITLE TEXT`: prints a complete IPPhoneText response, headers included
  - `cfw_data_dir FEATURE`: mkdir -p and print `/snom/cfw-data/FEATURE`
  - `cfw_rw` / `cfw_ro`: remount `/` rw/ro if needed (no-ops if already writable)
  - `cfw_game_running`: exit 0 if doom/infones/gpsp/any `/snom/cfw/*/` engine pid is alive
- Panel card fragment: the file `panel.d/NN-name.html` contains one `<div class="card">…</div>` and is concatenated in filename order by `cgi-bin/panel`.
- Phone menu entry: the file `phone-menu.d/NN-name` contains one line, `Label|/cgi-bin/<cgi>?<args>`. `phone-tools` renders these as IPPhoneMenu MenuItems with Url `http://127.0.0.1:8081<path>`.
- `tests/lib.sh`: `ph CMD…` (ssh to the phone, prints stdout), `ph_put LOCAL REMOTE` (cat over ssh, chmod preserved for 0755), `with_phone_lock CMD…`, `http GET-PATH` (curl :8080), `assert_eq`, `assert_contains`, `pass`/`fail` (exit nonzero on fail).

- [ ] Step 1: write `tests/foundation.sh`. It pushes the cfw tree to the phone under the lock (`/snom/cfw/{lib,cgi-bin,panel.d,phone-menu.d}`, restarts both httpds), then asserts that `http /cgi-bin/panel` contains all five existing card titles ("Boot Doom", "Boot NES", "Screenshot"…), that `curl http://127.0.0.1:8081/cgi-bin/phone-tools` run on the phone returns `<IPPhoneMenu`, and that `cfw_param` decodes `a%20b%26c` to `a b&c` and keeps `$(id)` literal.
- [ ] Step 2: run it and see it fail; Step 3: implement; Step 4: see it pass. Also check visually that the `phone-tools` menu opens under Settings on the phone (a screenshot via `/cgi-bin/screenshot` after injecting keys with `command.htm`).
- [ ] Step 5: commit.

---

The tasks below (A–J) run **in parallel**, each in its own worktree branched from the Task 0 commit.

### Task A: Scripts menu
**Spec:** "A 'Scripts' menu that runs your own shell scripts (wake-on-LAN, toggle lights, reboot a server) and shows the output."
**Files:** `cgi-bin/phone-scripts`, `cgi-bin/scripts` (panel: list/upload/edit/delete/run), `panel.d/60-scripts.html`, `phone-menu.d/10-scripts` (`Scripts|/cgi-bin/phone-scripts`), example scripts in `custom-rootfs/snom/cfw/scripts-examples/` (`wake-on-lan.sh` using a busybox `ether-wake` if present, otherwise a pure-sh magic packet through `nc -u`, plus `http-get.sh`), `tests/scripts.sh`, `docs/scripts.md`.
**Behaviour:** user scripts live in `/snom/cfw-data/scripts/*.sh`. The phone menu lists them by name. Selecting one runs it with `timeout 20` and shows its stdout+stderr (last 2000 bytes, xml-escaped) in IPPhoneText. Names are restricted to `[A-Za-z0-9._-]+\.sh`.
**Tests:** list, run an echo script and see its output, a 25 s script is killed at 20 s with a timeout message, a hostile name (`../x.sh`, `a;b.sh`) is rejected.

### Task B: Idle-screen widgets
**Spec:** "state_idle.xml is editable, so the standby screen could show a clock, stats or a custom picture."
**Files:** `custom-rootfs/snom/html/xml/gui/state_idle.xml` (keep `.orig`), `cgi-bin/idle-widget` (returns the widget text), `cgi-bin/idle` (panel config), `panel.d/70-idle.html`, `tests/idle.sh`, `docs/idle-screen.md`.
**Behaviour:** first find out on the device which elements of state_idle.xml can show fetched content (static XML first: Title/InfoBox text, images through any element that takes a file:// or http image). Then offer, configured in `/snom/cfw-data/idle/config`: a large clock, a stats line (uptime, load, free memory) and a custom picture (uploaded PNG stored in `/snom/cfw-data/idle/`). Show at most what the minibrowser really renders; report anything it doesn't.
**Tests:** each widget is checked by a screenshot (BMP to PNG, inspect it), and a stock-restore option puts the original back.

### Task C: Boot splash and theme icons
**Spec:** "Custom boot splash and theme icons, in the same way as the gamepad icon."
**Files:** `tools/make-splash.py` (any image to the exact format/size of `snom/bmp/colored/splash_screen.png` and the rcS D375 splashPng), `tools/theme-icons.py` (generalise `tools/make-games-icon.py`: replace any `icontype_icons/24x24/<enum>.png` in all 4 themes from a source PNG), optional panel upload `cgi-bin/splash` plus `panel.d/80-splash.html` (writes `/snom/cfw-data/splash.png`; rcS uses it if present, otherwise stock), the matching rcS change, `tests/splash.sh`, `docs/theming.md`.
**Tests:** reboot under the lock and capture the framebuffer during boot (poll `/cgi-bin/screenshot` or fb0 over ssh as soon as sshd is up) to show the custom splash; the tool output matches the stock PNG's dimensions and mode.

### Task D: Quit without reboot (reverse engineering)
**Spec:** "Find out how to restart media_daemon and the phone UI after a game, instead of rebooting."
**Files:** `custom-rootfs/snom/cfw/lib/phone-restore.sh`, the exit paths in `doom/boot-doom.sh` and `nes/boot-nes.sh` (call `phone-restore.sh`; fall back to `reboot` if the phone app isn't healthy within 60 s), `tests/restore.sh`, `docs/quit-without-reboot.md`.
**Known facts:** start.sh does `cd /snom; exec ./lid`. lid starts media_daemon and lcsD375. rcS loops on start.sh while `/tmp/ssh_fast_update` exists. snd_hal kills lid and media_daemon; lcsD375 survives orphaned, and Doom SIGSTOPs it. The stock media_daemon "won't restart by hand" (earlier observation). Use the REA tools on `decrypted/D375-10.1.64.17/snom/{lid,media_daemon,lcsD375}` to find how lid supervises its children and what media_daemon needs (devices, sockets, /tmp files, halaudio state) for a clean restart.
**Tests:** launch a game (test ROM), quit, phone UI back < 30 s, no reboot (uptime keeps growing), SIP registration state matches its pre-game state (check the stock web UI status page or `/snom` logs), audio works (a 5% keypress tone or ringtone preview), and a second game launch plus quit also works.
**Interface (produces):** `/snom/cfw/lib/phone-restore.sh`, exit status 0 = phone app healthy. Tasks E/F/K launchers call it.

### Task E: GB/GBC and GBA emulators
**Spec:** "Add GB/GBC and GBA emulator" (GBA on gpSP for performance; a WIP frontend exists on this branch, not yet verified on device).
**Files:** refactor `gba-src/gba_snom.c` into a generic `retro-src/snom_retro.c` (libretro frontend: fb scaling, evdev, snd_hal, audio-clocked pacing, core options table per core), `tools/build-gba.sh` → `tools/build-retro.sh` (builds `gpsp` and a GB/GBC core — choose a fast libretro core such as gambatte or gearboy and justify it by measured fps on the device — linking each core with the same frontend), `custom-rootfs/snom/cfw/{gba,gb}/{boot-*.sh,engine}`, `cgi-bin/boot-gba`, `cgi-bin/boot-gb`, `panel.d/45-gba.html`, `panel.d/46-gb.html`, the game entries for these in the phone Games menu (edit `cgi-bin/phone-games`, which this task owns from now on), `tests/retro.sh`, `docs/gba.md`, `docs/gb.md`.
**Tests:** hand-made test ROMs (a GBA one exists at `/tmp/claude-1000/-home-devlapi-Dokumente-GitHub-snomd375-firmware/de188260-3922-4701-b1bb-03089936f3dd/scratchpad/gbarom/sndtest.gba`; make a GB one) show the expected frame in a screenshot. `*_STATS=1` must report ≥ 55 fps for the test ROMs and give underrun counts. The sound dump (`SND_DUMP=1`) contains the expected tone frequencies (FFT on the host, at 5% volume). Also check that the launcher reports a bad URL or a non-ROM file.
**Keys:** GBA L = phone digit key `1`, R = digit key `3` (ruling; capture their scancodes on the device with a short evdev read while a test engine runs, or from Task J's table if merged). Log unmapped scancodes when `*_STATS=1` and document them.

### Task F: Custom ringtones (reverse engineering)
**Spec:** "Custom ringtones"
**Files:** `cgi-bin/ringtones` (panel upload/list/delete/preview), `panel.d/85-ringtones.html`, whatever config/XML wiring lcsD375 needs, `tests/ringtones.sh`, `docs/ringtones.md`.
**Approach:** find how stock ringtones are chosen and played (REA on lcsD375/media_daemon: the ringer setting names, the "custom melody" URL setting that snom phones support (`custom_melody_url`, check it), and the audio formats it accepts). Prefer the stock mechanism (a setting pointing to a file:// or http://127.0.0.1:8081 WAV) over patching binaries. Convert uploads on the host or phone to the accepted format (document it).
**Tests:** set the custom ringtone, trigger a ring preview at 5% volume (or capture it with the amxr tap, see `tools/halloop.c`) and confirm the PCM correlates with the uploaded file.

### Task G: Intercom / baby monitor
**Spec:** "Stream the mic to the PC over the amxr capture path we built for testing."
**Files:** `intercom-src/micstream.c` (based on `tools/halloop.c`: amxr_user_hook capture, 16 kHz mono S16LE, served over TCP and as HTTP `audio/wav` stream with an endless-length header), `tools/build-intercom.sh`, `custom-rootfs/snom/cfw/intercom/micstream`, the `amxr_user_hook.ko` handling (where it comes from, insmod at start), `cgi-bin/intercom` (start/stop), `panel.d/90-intercom.html` (with an `<audio>` element), `phone-menu.d/30-intercom`, `tools/intercom-listen.sh` (PC side: `curl … | aplay`/ffplay), `tests/intercom.sh`, `docs/intercom.md`.
**Constraints:** must work while the phone UI is running (no takeover) if the amxr tap allows that; show an on-phone indicator, or at least document clearly that the mic is live.
**Tests:** stream 5 s to the host and confirm it is valid PCM with non-silent energy when a 5% test tone plays from the speaker (or use ambient noise); stop works and frees the device.

### Task H: Panel password login
**Spec:** "The password login that's already planned." The plan is `docs/roadmap.md` lines 33-73; follow it.
**Files:** `custom-rootfs/etc/cfw-httpd.conf`, the rcS :8080 line (adds `-c /etc/cfw-httpd.conf -r "snom CFW"`), `docs/cfw-login.md`, an update to roadmap.md marking the plan done, `tests/login.sh`.
**Tests:** :8080 without credentials gives 401, a wrong password 401, `root:snom375` 200; `:8081` from the phone still works without credentials and is unreachable from the LAN; every `phone-menu.d` entry and phone-games URL returns 200 on :8081; reset-pw still works with auth.

### Task I: System info page
**Spec:** "System info page on admin web: CPU, memory, flash and /tmp usage, uptime, logs."
**Files:** `cgi-bin/sysinfo` (HTML: cpuinfo summary, load, `/proc/meminfo`, `df` of `/` `/tmp` `/protected`, mtd partitions, uptime, top 10 processes by RSS, and the last 100 lines of `dmesg` and of each `/tmp/*.log` and `/snom/cfw/*/last.log`, html-escaped), `cgi-bin/sysinfo.json` (the same numbers as JSON), `panel.d/15-sysinfo.html`, `tests/sysinfo.sh`, `docs/sysinfo.md`.
**Tests:** JSON keys present and numbers plausible (mem total 122720 kB ±10%); a log line containing `<script>` comes out escaped.

### Task J: Remote screen and keypad
**Spec:** "Combine the screenshot CGI with the command.htm key injection into a live 'remote control' page."
**Files:** `cgi-bin/remote` (HTML page: a canvas that polls `/cgi-bin/screenshot` (or a new PNG/low-res variant if BMP is too slow), plus an on-screen keypad and keyboard shortcuts), `cgi-bin/remote-key` (server-side proxy to `http://127.0.0.1/command.htm?key=…` with a key whitelist, so the page needs only :8080 and its auth), `panel.d/55-remote.html`, `tests/remote.sh`, `docs/remote.md`.
**Note:** during a game lcsD375 is stopped, so command.htm won't work. Inject keys straight into `/dev/input/event0` (as snd_hal's `inject_speaker` does) with a tiny static helper `remote-src/keyinject.c` → `custom-rootfs/snom/cfw/bin/keyinject`, using the scancode table from the docs. Map key names to scancodes; find the codes for digits and other keys through `getevent`-style capture on the device and record them in docs.
**Tests:** a key press changes the screen (screenshot diff), the whitelist rejects `key=$(reboot)`, and the frame rate is reported.

---

The tasks below (K, L) run **after A–J are merged**, in sequence, because they touch the engines that D and E change.

### Task K: Persistent saves
**Spec:** "Save games that survive the reboot … keeping them in a small folder on flash."
**Files:** NES (`nes-src/InfoNES_System_snom.cpp`: load and store battery SRAM in `/snom/cfw-data/saves/nes/<rom-sha1>.srm`, written on quit and every 30 s if changed), Doom (`-savedir /snom/cfw-data/saves/doom/` or the doomgeneric equivalent), GB/GBA (libretro `RETRO_MEMORY_SAVE_RAM` load/store in `retro-src/snom_retro.c`, same naming, `.srm`), the launchers pass the ROM hash, `cgi-bin/saves` plus `panel.d/48-saves.html` (list, download, delete), `tests/saves.sh`, `docs/saves.md`.
**Tests:** a save written, then a reboot (or restore) under the lock, and it's still there; a write failure on a read-only or full flash is logged.

### Task L: Keymap editor
**Spec:** "Keymap editor in the panel, so the phone keys can be remapped per game."
**Files:** `common/cfw_keymap.{c,h}` (`int cfw_keymap_load(const char *engine, const char *game, struct cfw_keymap *km)` parses `/snom/cfw-data/keymaps/<engine>/<game>.map`, falling back to `<engine>/default.map`, falling back to the built-in table; lines `<scancode> <ACTION>`, `#` comments), integrated into NES, Doom and the retro frontend, plus `cgi-bin/keymap` (panel editor: pick engine and game, then a table of phone keys → actions, with a "press a key" capture mode that reads the last scancode the engine logged or a short evdev capture when no game runs), `panel.d/47-keymap.html`, `tests/keymap.sh`, `docs/keymap.md`.
**Actions per engine:** nes `A B SELECT START UP DOWN LEFT RIGHT QUIT VOLUP VOLDOWN`, gb/gba the same plus `L R`, doom `UP DOWN LEFT RIGHT FIRE USE ENTER ESCAPE STRAFE RUN QUIT VOLUP VOLDOWN`.
**Volume keys (spec: "in games make volume key actually do volume"):** the default maps bind the phone's volume −/+ keys (scancodes captured on the device; Task J records them in docs/remote.md) to VOLDOWN/VOLUP. Add `void snd_hal_volume_step(int delta_pct)` and `int snd_hal_volume(void)` to `snd/snd_hal.{c,h}`: steps of 10%, clamped to 0..100, persisted in `/snom/cfw-data/volume` (a decimal percent, read at `snd_hal_init`; `SND_VOL` env still overrides it for tests). Default 50 when no file exists. Briefly draw the level on screen if that's easy; otherwise log it. All engines (NES, Doom, retro frontend) must handle it, and Doom must be rebuilt.
**Tests (volume):** inject VOLUP×2 → the volume file reads +20; the PCM dump amplitude scales accordingly.
**Tests:** a map file swaps A/B in the NES test ROM (inject a key with `keyinject`, check the effect), a malformed line is ignored with a log line, and the missing-file fallback works.

---

### Task Z: Integration (controller)
Merge A–J, then K, then L into `cfw-features`; regenerate `etc/checksum.md5` lines; update README and `docs/cfw-settings.md`; archive the old `.bin` to `custom-firmware/previous/`; build; flash under the lock; run every `tests/*.sh`; final whole-branch review.
