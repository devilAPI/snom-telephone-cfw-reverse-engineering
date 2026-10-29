# Scripts menu

Run your own shell scripts from the phone (wake-on-LAN, toggle lights, reboot a server) and see the output.

- Scripts live in `/snom/cfw-data/scripts/*.sh` (persistent, not part of the image).
- Phone: Settings -> CFW Tools -> Scripts lists them by name; selecting one runs it and shows stdout+stderr (last 2000 bytes) as an IPPhoneText screen.
- Web panel: the "Scripts" card -> `/cgi-bin/scripts` to create/edit (paste into textarea), delete and run.
- Examples: `/snom/cfw/scripts-examples/wake-on-lan.sh` (uses `ether-wake`, falls back to a magic packet through `nc -u`) and `http-get.sh`. Copy them into the scripts dir and edit.

## Files
`cgi-bin/phone-scripts` (phone menu + runner, via the auth-free loopback httpd on :8081), `cgi-bin/scripts` (panel), `lib/scripts-run.sh` (shared runner), `panel.d/60-scripts.html`, `phone-menu.d/10-scripts`, `tests/scripts.sh`.

## Gotchas
- **No `timeout` applet in the phone's busybox** (it has `ether-wake`, `nc`, `wget`, but not `timeout`). The 20 s limit is a watchdog loop in `scripts_run`; on expiry the whole process tree is killed.
- **Kill the parent before its children.** Killing `sleep 25` first lets the script continue to its next command; and killing only the shell orphans the `sleep`. `scripts_kill_tree` snapshots children (from `/proc/*/stat`; busybox `ps` has no `-o`), kills the parent, then the children.
- Names must match `[A-Za-z0-9._-]+\.sh` (no leading dot, max 64 chars); anything else (`../x.sh`, `a;b.sh`, `$(id).sh`, spaces) is rejected before any file access, and the name is only ever used quoted as a path under the scripts dir.
- Scripts run as root, with stdin from /dev/null, in a `sh` (ash) - not bash. The phone menu request blocks until the script ends (max 20 s); the minibrowser shows its own loading state.
- Output is capped at the last 2000 bytes and XML-escaped. A nonzero exit adds `[exit code N]`.
- A script that daemonizes itself (`&`) is killed only if it is still a descendant when the limit hits; use `nohup`/`setsid`-style detaching deliberately if you want a survivor.
- The panel saves via a textarea POST (CRLF stripped), not multipart upload: parsing multipart in busybox sh is fragile. Writing uses `cfw_rw`; a failure (flash full/read-only) shows an error message.
