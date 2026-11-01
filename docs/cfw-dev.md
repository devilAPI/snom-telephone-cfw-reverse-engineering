# CFW developer guide (shared foundation)

How the CFW web panel and the on-phone menus are assembled, and the helpers every feature uses.

## Layout (all under `custom-rootfs/snom/cfw/`, on the phone `/snom/cfw/`)

| Path | Purpose |
|---|---|
| `lib/cfw.sh` | shell helpers, `. /snom/cfw/lib/cfw.sh` |
| `cgi-bin/panel` | the web panel: page chrome + every `panel.d/*.html`, in filename order |
| `panel.d/NN-name.html` | one panel card each: a single `<div class="card">...</div>` |
| `cgi-bin/phone-tools` | the on-phone "CFW Tools" menu (Settings -> CFW Tools) |
| `phone-menu.d/NN-name` | one line `Label|/cgi-bin/<cgi>?<args>` per menu entry |
| `index.html` | only a redirect to `/cgi-bin/panel` |

Card number ranges in use: 10 reset-pw, 20 reset-ssh, 30 doom, 40 nes, 50 screenshot; other tasks pick their own NN (see the plan).
Adding a feature never needs an edit of `index.html`, `state_settings.xml` or `phone-tools`: drop a fragment into `panel.d/` and/or `phone-menu.d/`.

## Two httpds

* `:8080` (all interfaces): the admin panel. A password login is planned here (`docs/roadmap.md`).
* `127.0.0.1:8081` (loopback only): used by the phone's own minibrowser (lcsD375), so the on-phone menus keep working once `:8080` is password protected. `phone-menu.d` URLs, `phone-games` and `phone-url` therefore all use `http://127.0.0.1:8081`.
  Both are `busybox httpd -h /snom/cfw`, started in `etc/init.d/rcS` (D375 branch). CGIs are read per request, so deploying a CGI needs no restart; only a change to rcS needs a reboot/flash (or start the 8081 httpd by hand: `busybox httpd -p 127.0.0.1:8081 -h /snom/cfw`).

## cfw.sh API

* `cfw_param NAME`: url-decoded value from the POST body (read once, cached in `CFW_BODY`) or `QUERY_STRING`. NAME must match `[A-Za-z0-9_]+`. Backslashes are doubled before `printf %b` so they stay literal; `$(...)` is never evaluated. Always quote the result.
* `cfw_html_escape`, `cfw_xml_escape`: stdin to stdout (`& < > "`, xml also `'`).
* `cfw_html_head TITLE` (prints the Content-type header too) / `cfw_html_foot`.
* `cfw_phone_text TITLE TEXT`: full IPPhoneText response, with a CANCEL softkey.
* `cfw_data_dir FEATURE`: `mkdir -p` and print `/snom/cfw-data/FEATURE`; rejects names with `/` or `..`.
* `cfw_rw` / `cfw_ro`: remount `/` only if needed.
* `cfw_game_running`: exit 0 if any process whose exe is `/snom/cfw/*/*` is alive (doom, infones, gpsp, ...).

## Findings on the device

* `/` is **already mounted rw** (jffs2, `/dev/root on / type jffs2 (rw)`), and `/snom` is a plain directory in it (not a separate mount). Writing to `/snom` and creating `/snom/cfw-data` works without remount, so `cfw_rw`/`cfw_ro` are no-ops today; they exist for a future read-only rootfs. Free space on `/`: ~60 MB of 110 MB. `/snom/cfw-data` is not in the image, so it survives flashes only as far as the jffs2 partition is kept (a flash that rewrites rootfs may wipe it - verify before relying on it).
* `/protected` is a separate read-only jffs2.
* `pkill -f PATTERN` over ssh matches the ssh shell's own command line and kills the session; use `ps | awk '/[p]attern/{print $1}'`.
* Settings menus: `state_settings.xml` is read when the Settings menu opens, a copy to `/snom/html/xml/gui/` takes effect immediately (original backed up by the tests' author at `/tmp/state_settings.xml.bak` on the phone, lost at reboot). The new item sits after Games, scroll down in Settings to see it.
* The minibrowser only takes built-in icon enums for menus; CFW Tools reuses `kIconSettingsInformation`.

## Zip support
`lib/zip.sh` + `/snom/cfw/bin/unzip` (built by `tools/build-unzip.sh`), see [zip.md](zip.md). `cgi-bin/boot-gba` serves all four systems (`CFW_RETRO_SYS`).

## Tests

`tests/lib.sh` helpers: `ph`, `ph_put`, `with_phone_lock`, `http`, `assert_eq`, `assert_contains`, `pass`, `fail`. `tests/foundation.sh` deploys Task 0 files under the phone lock and checks panel cards, `phone-tools` on :8081 and `cfw_param` decoding.
