# CFW Settings web panel

A small admin page the custom firmware adds, separate from the stock snom web
UI, with buttons for common recovery actions. First two actions: reset the root
password to the firmware default, and restore the default `sshd_config`.

## Why it is a separate server

The stock web UI on port 80 **is** the phone application (`lcsD375`). It serves
the `.htm` templates in `/snom/html` and fills in `<?ssi ...?>` / `<?lng ...?>`
tokens itself. It has **no CGI** and only handles form POSTs for settings it
already knows, so a button that runs a shell command cannot go through it. The
left menu is generated inside the binary (`<?ssi leftnav_menu?>`), so a genuine
new menu entry can't be emitted there either.

What does work:

- `lcsD375` serves any **static** file dropped into `/snom/html` (verified).
- `leftnav.htm` is a real file, so a plain `<a>` row can be injected next to the
  generated menu entries.
- The rootfs ships **busybox `httpd`**, which does CGI.

So the panel is a `busybox httpd` instance on **port 8080** serving
`/snom/cfw`, and the menu just links to it.

## Pieces (all in `custom-rootfs/`)

| Path | What |
|---|---|
| `etc/init.d/rcS` (D375 case) | `busybox httpd -p 8080 -h /snom/cfw`, started right after sshd |
| `snom/cfw/index.html` | the page: two buttons, each a POST to a CGI |
| `snom/cfw/cgi-bin/reset-pw` | sets root password back to the default (`snom375`) |
| `snom/cfw/cgi-bin/reset-ssh` | restores `defaults/sshd_config`, reloads sshd (SIGHUP to the master) |
| `snom/cfw/defaults/sshd_config` | pristine default SSH config the reset restores from |
| `snom/html/leftnav.htm` | injected `CFW Settings` row linking to `http://<host>:8080/` |

The menu link builds its URL from `location.hostname` in the browser, so it
works at any IP.

## Security

Port 8080 is **not authenticated** (chosen deliberately). Anyone on the LAN who
can reach the phone can press these buttons and reset the root password or SSH
config. If that becomes a problem, put the panel behind busybox httpd basic auth
(an `/snom/cfw/httpd.conf` with a realm + `.htpasswd`), or firewall the port.

## "Default" values

- Root password default: `snom375` (see [signing-keys.md](signing-keys.md) and
  the build notes). Change it in `cgi-bin/reset-pw` (`DEFAULT_PW`) if you change
  the shipped default.
- SSH config default: whatever `snom/cfw/defaults/sshd_config` holds. The build
  ships a copy of `etc/ssh/sshd_config`; keep them in sync if you edit the live
  config.

## Notes for rebuilding

- New files under `/snom` are safe from the first-boot `cleanUpRootfs` pass
  (it only prunes `bin lib sbin usr`). `nano` lives in `usr/bin`, so it **is**
  listed in `etc/rootfs_files.lst` or it would be deleted on the first boot
  after an update.
- `etc/init.d/rcS` and `snom/html/leftnav.htm` are listed in
  `etc/checksum.md5`; editing them means refreshing their md5 entries or the
  build's `md5sum -c` check fails. The build script enforces this.

## On-phone Games menu (Settings → Games)

Doom and NES can be started from the phone itself, with no browser involved.

**How it hooks in.** The phone UI (`lcsD375`) builds its menus from snom
minibrowser XML in `/snom/html/xml/gui/`. `state_settings.xml` is the top-level
**Settings** menu. We add one `<Menu name="Games">` whose `<Url>` is
`http://127.0.0.1:8080/cgi-bin/phone-games`. The minibrowser fetches http URLs
like `file://` ones and renders the returned XML. `lcsD375` re-reads the file
each time the menu opens, so no restart is needed. The stock file is kept on the
phone as `state_settings.xml.orig`.

| CGI | Returns |
|-----|---------|
| `phone-games` | `IPPhoneMenu`: DOOM / NES; with `?game=doom\|nes`, the recent URLs (`/snom/cfw/<game>/history`), presets (Doom: shareware `DOOM1.WAD` from archive.org) and "Enter URL..." |
| `phone-url?game=` | `IPPhoneInput`: keypad URL entry; the typed text replaces `__U__` in the target URL |
| `phone-boot?game=&url=` | starts `boot-doom.sh` / `boot-nes.sh` detached, answers with an `IPPhoneText` "Starting..." |

The launchers record every URL that downloaded and validated in
`/snom/cfw/<game>/history` (newest first, max 8). Links used from the web panel
therefore show up in the phone menu too.

Remote testing without touching the phone: the stock web UI's
`http://<phone>/command.htm?key=SETTINGS|DOWN|ENTER|LEFT` injects keys, and
`/dev/fb0` (480x272 BGRX) can be dumped to PNG.
