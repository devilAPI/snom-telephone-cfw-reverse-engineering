#!/bin/sh
# phone-restore.sh - bring the stock phone app (lid + media_daemon + lcsD375)
# back after a game took over the screen, WITHOUT rebooting.
#
#   /snom/cfw/lib/phone-restore.sh        exit 0 = phone app healthy
#                                          exit 1 = could not restore (caller reboots)
#
# How it works (details and evidence: docs/quit-without-reboot.md):
#   The game takeover (snd/snd_hal.c) does `kill -9 lid media_daemon` while
#   /tmp/ssh_fast_update exists. rcS's startUpApplication loop then sits in
#   `while [ -f /tmp/ssh_fast_update ]; do sleep 1; done` and, once the flag is
#   gone, runs /snom/start.sh (exec ./lid) again. lid's children survive the
#   kill as orphans: lcsD375 (holds 127.0.0.1:1298 + the fb; Doom SIGSTOPs it),
#   bsa_server and dns-proxy (holds 127.0.0.1:53). A fresh lid would start new
#   copies that cannot bind those ports, so the orphans must die first. The
#   kernel side (halaudio, amxr routes, EPT) is cleaned up by the kernel when
#   the processes' fds close; the stock media_daemon re-inits it fine.
#   So: kill the orphans, drop the flag, wait for rcS to restart lid.
#
# Env: RESTORE_TIMEOUT (s, default 60), RESTORE_LOG (default /tmp/phone-restore.log)

FLAG=/tmp/ssh_fast_update
TIMEOUT=${RESTORE_TIMEOUT:-60}
LOG=${RESTORE_LOG:-/tmp/phone-restore.log}
# lid's children (and grandchild dns-proxy) that outlive a kill -9 of lid.
ORPHANS="lcsD375 bsa_server dns-proxy bt_ag_server media_daemon"

log() { echo "$(cut -d' ' -f1 /proc/uptime) phone-restore: $*" >> "$LOG"; }

# 127.0.0.1:<port hex> in LISTEN state (media_daemon 1299=0513, lcsD375 1298=0512)
listening() { grep -q "0100007F:$1 00000000:0000 0A" /proc/net/tcp; }

healthy() {
    pidof lid >/dev/null && pidof media_daemon >/dev/null && pidof lcsD375 >/dev/null &&
        listening 0513 && listening 0512
}

uptime_s() { cut -d. -f1 /proc/uptime; }

# Case 1: the phone app was never taken over (e.g. the game failed before
# snd_hal_init) - just undo a possible SIGSTOP and the flag.
if pidof lid >/dev/null; then
    kill -CONT $(pidof lcsD375) 2>/dev/null
    rm -f "$FLAG"
    if healthy; then log "lid still running, nothing to restore"; exit 0; fi
    # lid is up but not healthy (still starting?) - fall through to the wait.
    log "lid running but not healthy yet, waiting"
else
    # Case 2: lid is gone. rcS only restarts it while it is parked in the
    # fast-update loop, i.e. while the flag still exists.
    if [ ! -f "$FLAG" ]; then
        log "lid dead and $FLAG missing: rcS has left its loop, cannot restore"
        exit 1
    fi
    log "killing orphans: $ORPHANS"
    for p in $ORPHANS; do
        pids=$(pidof "$p")
        [ -n "$pids" ] || continue
        kill -CONT $pids 2>/dev/null    # stopped (Doom) processes: be explicit
        kill -9 $pids 2>/dev/null
    done
    i=0
    while [ $i -lt 10 ]; do
        alive=""
        for p in $ORPHANS; do pidof "$p" >/dev/null && alive="$alive $p"; done
        [ -z "$alive" ] && break
        usleep 300000; i=$((i + 1))
    done
    [ -n "$alive" ] && log "still alive after kill -9:$alive (continuing)"
    sync
    log "removing $FLAG, rcS restarts /snom/start.sh"
    rm -f "$FLAG"
fi

start=$(uptime_s)
while :; do
    if healthy; then
        log "phone app healthy after $(( $(uptime_s) - start )) s"
        exit 0
    fi
    if [ $(( $(uptime_s) - start )) -ge "$TIMEOUT" ]; then
        log "phone app NOT healthy after ${TIMEOUT} s (lid=$(pidof lid) md=$(pidof media_daemon) lcs=$(pidof lcsD375))"
        exit 1
    fi
    sleep 1
done
