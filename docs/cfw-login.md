# CFW panel login (same password as SSH)

The CFW panel on port 8080 asks for HTTP Basic credentials: user `root`, and
the same password as SSH.

## How it works

`rcS` starts the panel as

    busybox httpd -p 8080 -h /snom/cfw -c /etc/cfw-httpd.conf -r "snom CFW"

and `/etc/cfw-httpd.conf` contains one line, `/:root:*`. In busybox httpd a
`*` in the password field means "check against the system password database",
here `/etc/shadow` (root's hash is SHA-256 `$5$`). No new code: `passwd` over
SSH or the panel's "Reset root password" button changes the web login at the
same moment, because httpd re-reads `/etc/shadow` on each request.

Verified on the device (2026-10-29, throwaway instance on :8099): no
credentials 401, wrong password 401, wrong user 401, `root`/SSH password 200.

## The phone's own menus use a second port

`lcsD375` (the phone UI) fetches the Games / CFW Tools menus from the CFW
httpd, and its minibrowser cannot send credentials. busybox httpd applies the
`-c` rules regardless of client IP, so a loopback exception is not possible.
Therefore `rcS` runs a second instance, `busybox httpd -p 127.0.0.1:8081 -h
/snom/cfw`, with no `-c`. It is bound to 127.0.0.1, so it is unreachable from
the LAN (tested: connection refused). `state_settings.xml` and the
`phone-menu.d` entries point at `http://127.0.0.1:8081`.

Gotcha: anything new that the phone UI must fetch has to use :8081. A URL on
:8080 from the phone will get a 401 and the menu will show an error.

## Risks

- **Plain HTTP.** Basic auth is base64, not encryption: anyone sniffing the LAN
  sees the root password on every request. There is no TLS in busybox httpd.
  Acceptable on a trusted LAN. Option for later: a panel-only user
  (`/:admin:$5$...` line) so a sniffed web password is not the root password.
- **Lockout.** A forgotten password locks out both panel and SSH. Recovery is
  the OpenVPN root path ([root-access.md](root-access.md)) or a reflash with a
  known `/etc/shadow`.
- The reset-pw CGI sits behind the login: it is for changing the password back
  to `snom375`, not for recovery.
- `$REMOTE_USER` is set by httpd, so CGIs can log who did what (not done yet).

## Testing

`tests/login.sh` restarts :8080 with auth under the phone lock, checks 401/200
cases, :8081 from the phone vs. the LAN, every `phone-menu.d` URL on :8081 and
reset-pw with credentials, then restores the unauthenticated :8080 (the
unauthenticated state is what the other test scripts expect until this image
is flashed).
