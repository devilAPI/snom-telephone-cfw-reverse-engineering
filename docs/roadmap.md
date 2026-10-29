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
| _ideas, e.g. extra tools (busybox applets, tcpdump), custom web UI pages, logging to syslog server, removing phone-home/provisioning_ | open |

For each feature, record here which files it touches and how it was tested on the device.

## Plan: password protection for the CFW panel (same login as SSH)

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
