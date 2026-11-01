# System info page

`/cgi-bin/sysinfo` (HTML) and `/cgi-bin/sysinfo.json` on the admin web (:8080). Card: `panel.d/15-sysinfo.html`.
Test: `tests/sysinfo.sh` (deploys the two CGIs, checks JSON keys, mem total 122720 kB +-10 %, XSS escaping).

## What it shows
uptime and load, CPU (ARM1176, single core, BogoMIPS), `/proc/meminfo`, `df -k` of `/`, `/tmp`, `/protected`,
`/proc/mtd`, top 10 processes by RSS, `dmesg` tail and the last 100 lines of `/tmp/*.log` and `/snom/cfw/*/last.log`.

## Gotchas
- Busybox `ps` here has no RSS column, so RSS is read from `/proc/PID/VmRSS` (kernel threads have none and are skipped).
  Process names come from `/proc/PID/status` (truncated to 15 chars, can be odd, e.g. a process named `12`).
- No `timeout` binary on the phone; nothing here needs it.
- Log files are untrusted data (anything a process printed, a game's stdout, even a ROM name). Every byte goes through
  `cfw_html_escape` (HTML) or a JSON string escaper (JSON). The JSON only contains numbers and process/CPU/partition names.
- `/tmp` is a 40 MB tmpfs: games' `.log` files live there and count against RAM.
- Load average is high (~5) while lcsD375 runs; that is normal on this phone.
- The JSON CGI is standalone (no cfw.sh) so it stays cheap enough to poll.
- Page runs ~72 small `sed` calls for the process list; takes about a second on the phone.

## JSON shape
`{"uptime_s","load":{"1","5","15"},"cpu":{"model","bogomips","count"},"mem":{"total_kb","free_kb","buffers_kb","cached_kb","swap_total_kb"},"fs":{"root|tmp|protected":{"size_kb","used_kb","avail_kb"}},"mtd":[{"dev","size","name"}],"procs":[{"pid","rss_kb","name"}]}`
