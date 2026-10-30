# Idle-screen widgets

Panel card "Idle screen widgets" (`panel.d/70-idle.html`) -> `cgi-bin/idle`. Config lives in `/snom/cfw-data/idle/config` (`clock=on`, `stats=on`, `picture=on`), the picture in `/snom/cfw-data/idle/picture.png`.

## How it works (and why)

`/snom/html/xml/gui/state_idle.xml` is the standby screen. Findings on the device:

* **lcsD375 parses it once, when the UI process starts.** Overwriting the file on a running phone changes nothing, not even after Settings -> Cancel (tested with a changed `<Title>`). Applying a change therefore means restarting `lcsD375` (`lid` respawns it, ~20 s, calls/games are interrupted). `cgi-bin/idle` does this itself.
* The page re-runs every second (`<Fetch mil="1000">phone://mb_nop</Fetch>`), so **macros are live** (`$(time)`, `$(date)`), but nothing can pull text from a file or URL into this page. Hence:
  * **Clock**: `$(time)` in an `<InfoBox>` line, live.
  * **Stats line**: text baked in at apply time (`cgi-bin/idle-widget`: uptime, load, free RAM incl. cache). It is *frozen* until the next Apply; it is not a live gauge.
  * **Picture**: `<Image>File:///bmp/cfw-idle.png</Image>` in an InfoBox line; `/snom/html/bmp/cfw-idle.png` is a symlink to the stored PNG. Fetch it from the panel by URL (no multipart upload in busybox sh), or put it in the data dir over ssh.
* `state_idle.xml.orig` is the untouched stock file; the generator inserts one `<InfoBox>` after `<SelectedTextHighlight>` (inside the `FEATURE_PUI_STYLE_SIO` branch) into a copy of it. "Restore stock" copies the `.orig` back.

## Gotchas

* A broken `state_idle.xml` would break the idle screen at the next UI start: keep `.orig`, the restore button, and `tests/idle.sh` (restores in a trap).
* Another session's game (gpsp/doom) SIGSTOPs lcsD375 and kills lid; do not apply while a game runs.


## Tests

`tests/idle.sh`: deploys, applies all three widgets, screenshots to `/tmp/idle-test/widgets.png`, restores stock, screenshots `stock.png`.

## Result on the device (honest status)

The pipeline works (config, generated XML correct, lcsD375 killed with `kill -9` and respawned by `lid`, stock restore byte-identical), but **the minibrowser did not render the inserted `<InfoBox>` (clock, stats, picture) on the idle screen**, in screenshots after the UI restart. In the stock file `<InfoBox>` is only used for status messages and is probably only shown for those. So the widgets are currently *not visible*; this is unresolved. Untried alternatives: put the text in `<Title>` (live macros work there; stock already shows `$(date)` and the time), or in the identity `<Subtext>`; an `<Image>` inside a `MenuItem`. Plain `kill` (SIGTERM) does not restart lcsD375; `kill -9` does.
