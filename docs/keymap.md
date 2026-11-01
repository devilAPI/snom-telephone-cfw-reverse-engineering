# Key maps and volume keys

Every game engine (NES, Game Boy / Color, GBA, Doom) maps phone keys to game actions through one shared header, `snd/cfw_keymap.h`. The maps are plain files, editable in the panel (**Key maps** card, `/cgi-bin/keymap`) or by hand.

## Files

```
/snom/cfw-data/keymaps/<engine>/<game>.map     one game
/snom/cfw-data/keymaps/<engine>/default.map    all games of that engine
(built-in table in the engine)
```

`<engine>` is `nes`, `gb`, `gba` or `doom`. `<game>` is the id the launcher passes in `CFW_GAME_ID`: the ROM's SHA-1 (the same id as the save file, see `docs/saves.md`; `lib/saves.sh` exports it) or, for Doom, the IWAD name (`doom2`, `freedoom1`, ...). Lookup order: game map, then `default.map`, then built-in. A file without a single valid line counts as absent, so a half-written or empty file can never leave a game without keys.

Format, one assignment per line:

```
# comment
120 B        # scancode  ACTION
116 A
```

Scancodes are the evdev codes from `docs/remote.md` (1..255). A key has one action; a later line for the same key wins. A malformed line, a scancode out of range or an action the engine does not have is skipped and logged once on the engine's stderr (the launcher log, `/tmp/nes.log` etc.): `keymap: <file>:<line>: ignoring malformed line`. The log also says which source won (`keymap: <path>` or `keymap: built-in`).

## Actions

| Engine | Actions |
|---|---|
| nes | `A B SELECT START UP DOWN LEFT RIGHT QUIT VOLUP VOLDOWN` |
| gb, gba | the same plus `L R` |
| doom | `UP DOWN LEFT RIGHT FIRE USE ENTER ESCAPE STRAFE RUN QUIT VOLUP VOLDOWN` |

`STRAFE` and `RUN` are Doom's Alt and Shift (hold). Built-in layout: D-pad = arrows, key 120 (Enter/OK) = A / FIRE, 116 (F1) = B / USE, 97 (Cancel) = START / ENTER, 115 (F2) = SELECT / ESCAPE, 51 / 48 (digits 1 / 3) = L / R on GB and GBA, 114 (F3, red hangup) = QUIT, 16 = VOLDOWN, 119 = VOLUP.

Safety rule (ruling): if the hangup key 114 is not assigned to anything in the map it still quits, so a bad map can never trap you in a game. Assign 114 to another action on purpose and it stops quitting; give some other key `QUIT`.

Maps are read when the game starts; editing one while a game runs takes effect on the next start.

## Panel editor

`/cgi-bin/keymap?eng=nes&game=default`: pick the engine, pick the game (default, or any id that has a save or a map; Doom always offers the common IWAD names), set an action per phone key, **Save map**. Only valid assignments are written (the CGI whitelists the action per engine and the scancode against the key table), via a `.tmp` file and `mv`. **Remove this map** deletes the file. A game's id is its ROM SHA-1, so the dropdown lists games once they have a save or a map; for a new game type nothing: edit `default`, or play it once (battery games) and reload.

"Press a key" (`/cgi-bin/keymap?act=capture`, blocks at most 8 s) returns a scancode and the page scrolls to that row:

* While a game runs the engine writes every key press to `/tmp/cfw-lastkey` (a few bytes in RAM); the CGI deletes the file, then waits for it to reappear.
* With no game running the CGI reads `/dev/input/event0` for a short time (`dd` into `/tmp/cfw-cap`, parsed with `od -d`; busybox `od` has no `-An`/`-t`). The phone's own UI sees the key too, so pressing e.g. Menu also does what Menu does.

## Volume keys

The default maps bind key 16 (Volume -) to `VOLDOWN` and 119 (Volume +) to `VOLUP`. `snd/snd_hal.{c,h}` gained:

* `void snd_hal_volume_step(int delta_pct)`: the engines call it with +-10; it clamps to 0..100, applies the gain to the next audio chunk, logs `volume: N%` and writes the level to `/snom/cfw-data/volume` (`.tmp` + `rename`).
* `int snd_hal_volume(void)`: current percent.
* `snd_hal_init` reads `/snom/cfw-data/volume` (decimal percent). **Default 50** when the file is missing or unreadable (this is lower than the previous fixed 100%). `SND_VOL=<percent>` overrides the file for bench tests and is then never persisted (stepping still works in memory).

Rulings: steps of 10 points on a linear scale (the speaker is very loud, so 0..100 in steps of ten is coarse enough at the low end only because the default is 50); no on-screen indicator (each engine draws straight into the fb with its own scaler, an overlay would need three more code paths), the level goes to the log instead; the phone's own volume setting is not touched.

## Tests

`tests/keymap.sh` (phone, ~6 min, holds the phone lock): idle and in-game key capture; NES test ROM runs with a game map (A/B swapped, three bad lines ignored with log lines), only `default.map`, and no map (built-in); volume: stored 5%, `VOLUME_UP` x2 gives 25 in the file and the PCM dump (`SND_DUMP=1`) gets about 5x louder, `VOLUME_DOWN` steps back; CGI save / reset / hostile ids. The effect of a mapping is checked through `CFW_KEYMAP_DEBUG=1`, which makes the engine log `keymap: key <code> -> <ACTION>` per press (the NES test ROMs draw nothing that distinguishes A from B). Only the NES engine is run on the phone for the mapping tests; the Game Boy / GBA frontend and Doom use the same header and the same few lines of glue and were built and booted for smoke checks only.
