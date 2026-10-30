# Persistent game saves

Games keep their saves on the phone's flash, in `/snom/cfw-data/saves/`, so they survive quitting a game, `phone-restore`, and reboots.
Everything else about a game run is still RAM-only (ROM/WAD are downloaded to `/tmp` and deleted).

| Game | What is saved | File |
|---|---|---|
| NES (InfoNES) | the 8 KiB battery SRAM ($6000-$7FFF), only for cartridges with the iNES battery flag | `saves/nes/<rom-sha1>.srm` |
| Game Boy / Color (Gambatte) | cart RAM (`RETRO_MEMORY_SAVE_RAM`) | `saves/gb/<rom-sha1>.srm` |
| GBA (gpSP) | SRAM/Flash/EEPROM (`RETRO_MEMORY_SAVE_RAM`) | `saves/gba/<rom-sha1>.srm` |
| Doom | the in-game savegames (`doomsav0.dsg` ...) via `-savedir` | `saves/doom/<iwad-name>/` |

`<rom-sha1>` is `sha1sum` of the downloaded ROM, so the same game from a different URL finds the same save, and a different ROM never reads someone else's save. Doom savegames are only valid for the IWAD they were made with, so they are keyed by IWAD name (`doom2`, `freedoom1`, ...).

## How it works

* The launcher (`lib/saves.sh`, sourced by `nes/boot-nes.sh`, `lib/retro-boot.sh`, `doom/boot-doom.sh`) hashes the ROM, creates the directory and passes the path to the engine in the environment variable `CFW_SAVE_FILE` (Doom: `-savedir DIR`).
* The engines share `snd/snom_save.h` (header only): `sv_load` reads the file into the emulator's battery RAM before the game starts; `sv_store` writes `<file>.tmp`, `fsync`s and `rename`s, so a power loss never leaves a half-written save.
* A save is written **when the emulator quits** (hangup key, or the game resetting out), on **SIGTERM** (the signal handler only sets a flag; the frame loop then does a normal `exit(0)` so the `atexit` flush runs), and **every 30 s if the RAM changed** (compared against a copy of what is on flash, so an idle game does no flash writes and a failed write is retried only after the RAM changes again, not every 30 s). `SIGKILL` and power loss lose at most 30 s.
* The exit flush is registered after `snd_hal_shutdown`, so it runs first: the save never waits for audio teardown.
* The launchers `sync` after the engine exits, before `phone-restore`.
* Failures never stop the game. A read-only or full flash makes `sv_store` print `save: cannot write ...` (or `write ... failed`, `fsync`, `rename`) to the engine's stderr, which is the launcher log (`/tmp/nes.log`, `/tmp/gb.log`, `/tmp/gba.log`, `/tmp/doom.log`; Doom prints its own "Failed to open savegame" error). The old save stays intact because the rename never happens.
* Cartridges without battery RAM (GB ROM-only, NES without the battery flag) get no file: the engine sees `retro_get_memory_size() == 0` / no battery flag and does nothing.

Not saved (ruling): GB real-time-clock data (`RETRO_MEMORY_RTC`) and emulator save *states*; both are out of scope for "save games".

## Web panel

`panel.d/48-saves.html` links to `/cgi-bin/saves`: list (size, date), download, delete (POST, refused while a game is running). Paths are validated component by component (`[A-Za-z0-9._-]`, no leading dot, 2-3 components), so `..`, absolute paths and the `.tmp` files are rejected. Downloading a `.srm` gives a standard battery-save file usable in other emulators (for GBA/GB, a raw dump of the cart memory).

## Gotchas

* `/snom/cfw-data` is jffs2 flash in the rootfs partition but is not part of the firmware image: a flash that rewrites the rootfs may wipe it (see `docs/cfw-dev.md`). Download saves from the panel before flashing.
* iNES trainers are copied into SRAM at $7000 when the ROM is read; the save file, a full 8 KiB dump, is read afterwards and wins. Trainer ROMs are rare.
* Doom's `-savedir` path was wired into the launcher but not run on the phone in this task (no WAD available offline); Doom itself writes savegames immediately, and the launcher `sync`s after exit.
* gpSP reports its backup size from the detected save type; a game that has not touched its save memory yet may have no save file until it does.

## Tests

`tests/saves.sh` (deploy and run under the phone lock, ~8 min): test ROMs `tests/roms/sav.{nes,gb,gba}` (made by `mkroms.py` / `build.sh`) increment byte 0 of battery RAM on every start. Checks: counter 1 after the first run, 2 after the second (proves load), SIGTERM flush, a blocked `.tmp` path logs `save: cannot write` and keeps the old save, plus the CGI (list, download, hostile names, delete).

A ROM that came out of a zip is moved to the normal ROM path before `saves_setup` hashes it, so it gets the same save as the bare ROM (see zip.md).
