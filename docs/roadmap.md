# Roadmap and workflow

## Workflow goal: stock + overlay

Today the whole modified rootfs (`custom-rootfs/`) lives only on disk, and it
has been lost once already. The plan is to make every image reproducible from
two inputs:

1. a stock snom image (`original_firmware/`, downloadable, not committed), and
2. an `overlay/` directory **in git** with our added/changed files, plus a
   small manifest for modes, owners and deletions.

Then `build = unpack stock → apply overlay → sign`. The private key is the only
secret that has to be stored outside git.

Steps:

- [ ] Recover the current changes with `rootfs-diff.sh` ([recover-from-device.md](recover-from-device.md))
- [ ] Move them into `overlay/` and add `tools/apply-overlay.sh`
- [ ] Let `build-custom-firmware.sh` take a stock image + overlay directly
- [ ] Check that a clean rebuild matches the rootfs pulled from the phone

## Features

| Feature | Status |
|---|---|
| Root SSH on every boot | done (files need recovering into the overlay) |
| Custom firmware signing key | done (rekeying documented) |
| Ideas | see the list below |

For each feature, record here which files it touches and how it was tested on the device.

## Ideas (to do)

These aren't built yet. Each one has a rough size: S is an evening, M a few
days, L a project. Things that already exist (games, intercom, ringtones,
remote screen, scripts, idle widgets, keymap, saves, theming, splash, backup)
aren't listed.

### Phone and calls

- [ ] **Call log export** (S): a panel page and CSV download of the call history.
- [ ] **Call recording to flash or a network share** (M): the Record key
      exists. Needs a capture path from halaudio, see
      [sound.md](sound.md).
- [ ] **Blocklist and caller rules** (S): reject or silence numbers by
      pattern, with a panel editor.
- [ ] **Do-not-disturb schedule** (S): DND on a timer, such as nights and
      weekends.
- [ ] **Caller lookup** (M): look up an incoming number in a CardDAV or
      LDAP address book, or a reverse-search URL, and show the name.
- [ ] **Voicemail as audio** (M): play messages from the Fritz!Box
      answering machine on the phone.

### Home and network

- [ ] **MQTT client** (M): publish call and key events, and run a script from
      an MQTT message. Home Assistant integration comes almost for free.
- [ ] **Home Assistant widgets** (M): idle-screen tiles for sensor values, and
      function keys that toggle entities ([idle-screen.md](idle-screen.md)).
- [ ] **Webhook on events** (S): call a URL on ring, answer, hang-up and key
      press. This is MQTT without a broker.
- [ ] **Doorbell and intercom with a camera** (M): show a snapshot or MJPEG frame
      when a door SIP call comes in ([intercom.md](intercom.md)).
- [ ] **Wake-on-LAN key** (S): one script and a key preset.

### Screen

- [ ] **Clock and weather screensaver** (S): uses the idle-widget code.
- [ ] **Photo frame mode** (S): cycle images from `/snom/cfw-data/photos` when
      idle.
- [ ] **Notifications** (M): a CGI or MQTT topic that shows a message popup
      on the phone, from the server, a calendar or CI.
- [ ] **Theme editor in the panel** (M): live colour and font preview
      ([theming.md](theming.md)).

### Games and fun

- [ ] **More emulators** (M each): SMS/Game Gear, Atari 2600 and CHIP-8. They
      are small and suit the screen.
- [ ] **ScummVM or a small native game** (L): Tetris or Snake runs on the keypad.
- [ ] **Music player** (M): MP3 or internet radio through the speaker or headset.
      The audio path is solved ([sound.md](sound.md)).

### System and dev

- [ ] **OTA update from the panel** (M): upload a signed .bin in the panel, so
      the web-page POST trick from
      [backport-guide.md](backport-guide.md) isn't needed.
- [ ] **Syslog forwarding** (S): send the app's and the kernel's logs to a
      server.
- [ ] **Extra tools** (S): tcpdump, strace, a fuller busybox, and nano is
      already documented ([building-nano.md](building-nano.md)).
- [ ] **Turn off phone-home and provisioning** (S): block snom's redirect or
      provisioning servers by default.
- [ ] **Watchdog for the phone app** (S): restart lcsD815 if it dies,
      without rebooting the phone.
- [ ] **Find the idle load average of 5** (M): profile it with `perf` or `top`
      snapshots. It's also on [to-test.md](../to-test.md).
- [ ] **Stock + overlay build** (M): the workflow at the top of this file.
- [ ] **Panel over HTTPS** (M): a small TLS terminator, so the panel login
      isn't sent in plaintext.
- [ ] **One codebase for several models** (L): see
      [multi-model.md](multi-model.md).

## Done: password protection for the CFW panel (same login as SSH)

**Status: implemented** (see [cfw-login.md](cfw-login.md), test `tests/login.sh`). The plan below is kept for the reasoning.

**Finding (tested on-device 2026-10-29):** the phone's busybox `httpd` can
check Basic-auth logins against the system password database. With
`/:root:*` in its `-c` config, `*` means "use `/etc/shadow`" (root's hash is
SHA-256 `$5$`). A throwaway instance on port 8099 answered 401 with no creds,
401 with a wrong password and 200 with `root` / the SSH password. So "Linux
auth" needs no new code. It's one config file plus `-c`/`-r` flags.

**Proposed design**

1. `custom-rootfs/etc/cfw-httpd.conf`: `/:root:*`. rcS starts the panel as
   `busybox httpd -p 8080 -h /snom/cfw -c /etc/cfw-httpd.conf -r "snom CFW"`.
   Changing the password with `passwd` over SSH, or with the panel's
   reset-pw button, changes both logins at once.
2. **The phone's own Games menu can't log in.** `lcsD375` fetches
   `http://127.0.0.1:8080/cgi-bin/phone-*` and the minibrowser can't send
   credentials, and busybox applies auth regardless of client IP. So run a
   second, auth-free instance bound to loopback only, e.g.
   `busybox httpd -p 127.0.0.1:8081 -h /snom/cfw-local`. It would serve only
   the `phone-*` CGIs (symlinks), unreachable from the LAN, and
   `state_settings.xml` / `phone-games` would point at `:8081`.
3. CGIs can log `$REMOTE_USER` for an audit trail. Optional.

**Risks / decisions**

- **Plain HTTP.** Basic auth sends the root password base64-encoded (not
  encrypted) on every request, so anyone sniffing the LAN gets the SSH root
  password. There is no TLS in busybox httpd and no stunnel on the phone.
  Options: accept it on a trusted LAN; use a separate panel-only password
  (`/:admin:$5$...` line) so a sniffed web password isn't the root password;
  or cross-build a TLS terminator later.
- **Lockout.** If the password is forgotten, panel and SSH are both gone.
  Recovery is the OpenVPN root path ([root-access.md](root-access.md)) or a
  reflash with a known `/etc/shadow`.
- The reset-pw CGI then sits behind the login, which is fine (it's for
  changing, not recovering).

**Test plan:** 401/200 with curl as above on :8080; the browser prompts and the
panel works; the phone menu still boots Doom via :8081; `curl` from the LAN to
:8081 is refused; `passwd` over SSH changes the web login immediately.
