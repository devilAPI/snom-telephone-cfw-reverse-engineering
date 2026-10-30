#!/bin/bash
# Task D test: quit a game WITHOUT rebooting the phone.
#   - deploys phone-restore.sh + the NES/Doom launchers,
#   - launches the NES test ROM through the real launcher (boot-nes.sh),
#     quits it with an injected red-hangup key, and checks that:
#       the phone app is healthy again in < 30 s, the phone did NOT reboot
#       (uptime keeps growing), SIP registration returns to its pre-game state,
#       and media_daemon produces audio again (a quiet dial tone, tapped
#       digitally from the DSP's loudspeaker feed via amxr_user_hook),
#   - does a second launch + quit (Review Focus 5: relaunch must work).
# Everything disruptive runs under the shared phone lock. Game audio at 5 %.
. "$(dirname "$0")/lib.sh"
C=$REPO/custom-rootfs/snom/cfw
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD" "$_askpass"' EXIT

sip_state() {   # "Identity 1 Status <aor>: OK" from the stock web UI
    curl -s -m 10 "http://$PHONE_IP/info.htm" | sed 's/<[^>]*>/ /g' | tr -s ' \n' |
        grep -o 'Identity 1&nbsp;Status [^ ]* [A-Za-z]*' | head -n 1
}
uptime_s() { ph 'cut -d. -f1 /proc/uptime'; }
healthy() {
    ph 'pidof lid >/dev/null && pidof media_daemon >/dev/null && pidof lcsD375 >/dev/null &&
        grep -q "0100007F:0513 00000000:0000 0A" /proc/net/tcp &&
        grep -q "0100007F:0512 00000000:0000 0A" /proc/net/tcp && echo yes'
}
# press+release one evdev key on the phone (32-byte input_event pairs, busybox printf)
key() {
    local o; o=$(printf '%03o' "$1")
    ph "printf '\\000\\000\\000\\000\\000\\000\\000\\000\\001\\000\\$o\\000\\001\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000' > /dev/input/event0; usleep 80000;
        printf '\\000\\000\\000\\000\\000\\000\\000\\000\\001\\000\\$o\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000' > /dev/input/event0"
}

deploy() {
    ph_put "$C/lib/phone-restore.sh" /snom/cfw/lib/phone-restore.sh
    ph_put "$C/nes/boot-nes.sh"      /snom/cfw/nes/boot-nes.sh
    ph_put "$C/doom/boot-doom.sh"    /snom/cfw/doom/boot-doom.sh
    ph_put "$C/cgi-bin/boot-nes"     /snom/cfw/cgi-bin/boot-nes
    ph_put "$C/cgi-bin/boot-doom"    /snom/cfw/cgi-bin/boot-doom
    ph_put "$REPO/tests/roms/tone.nes"      /tmp/restore-test.nes
    ph_put "$REPO/tests/helpers/amxrtap"    /tmp/amxrtap
}

# One game cycle through the real launcher. Prints the restore duration (s).
game_cycle() {
    local n=$1 i
    ph 'rm -f /tmp/phone-restore.log; cp /snom/cfw/nes/history /tmp/nes-history.bak 2>/dev/null
        SND_VOL=5 nohup /snom/cfw/nes/boot-nes.sh file:///tmp/restore-test.nes >/dev/null 2>&1 &'
    for i in $(seq 30); do
        [ -n "$(ph 'pidof infones')" ] && [ -z "$(ph 'pidof lid')" ] && break
        sleep 1
    done
    [ -n "$(ph 'pidof infones')" ] || { ph 'cat /tmp/nes.log' >&2; fail "run $n: emulator did not start"; }
    [ -z "$(ph 'pidof lid')" ] || fail "run $n: takeover did not stop lid"
    pass "run $n: emulator owns the screen (lid stopped)"
    sleep 5
    key 114                                   # red hangup = quit
    for i in $(seq 90); do
        ph 'grep -q -e "phone app restored" -e "rebooting" /tmp/nes.log' && break
        sleep 1
    done
    local L; L=$(ph 'cat /tmp/nes.log')
    # boot-nes.sh records file:// URLs in the Games history: put it back.
    ph 'if [ -f /tmp/nes-history.bak ]; then mv /tmp/nes-history.bak /snom/cfw/nes/history; else rm -f /snom/cfw/nes/history; fi'
    assert_contains "$L" "phone app restored" "run $n: launcher restored the phone app"
    local secs; secs=$(ph 'sed -n "s/.*healthy after \([0-9]*\) s.*/\1/p" /tmp/phone-restore.log')
    echo "  run $n: phone app healthy $secs s after the flag was dropped"
    [ -n "$secs" ] && [ "$secs" -lt 30 ] && pass "run $n: restored in < 30 s" || fail "run $n: restore took ${secs:-?} s"
    [ "$(healthy)" = yes ] || fail "run $n: phone app not healthy"
}

# Quiet dial tone (vol_speaker=1, handsfree) tapped from ept.bind1, the DSP's
# loudspeaker feed. Leaves the phone on-hook and the volume as it was.
audio_check() {
    local vol had_hook rms
    vol=$(curl -s -m 20 "http://$PHONE_IP/settings.htm" | grep -o "updateSetting('vol_speaker', '[0-9]*')" | grep -o "[0-9]*'" | tr -d "'")
    had_hook=$(ph 'grep -c "^amxr_user_hook " /proc/modules')
    ph '[ -c /dev/amxruser ] && grep -q "^amxr_user_hook " /proc/modules || insmod /lib/modules/2.6.27.47/BROADCOM/amxr_user_hook.ko'
    curl -s -m 10 -o /dev/null "http://$PHONE_IP/dummy.htm?settings=save&vol_speaker=1"
    curl -s -m 10 -o /dev/null "http://$PHONE_IP/command.htm?key=SPEAKER"
    ph '/tmp/amxrtap ept.bind1 300 /tmp/restore-tap.raw'
    curl -s -m 10 -o /dev/null "http://$PHONE_IP/command.htm?key=SPEAKER"
    [ -n "$vol" ] && curl -s -m 10 -o /dev/null "http://$PHONE_IP/dummy.htm?settings=save&vol_speaker=$vol"
    [ "$had_hook" = 0 ] && ph 'rmmod amxr_user_hook'
    ph 'cat /tmp/restore-tap.raw; rm -f /tmp/restore-tap.raw' > "$TMPD/tap.raw"
    rms=$(python3 -c '
import array,sys,math
a=array.array("h",open(sys.argv[1],"rb").read())
print(int(math.sqrt(sum(x*x for x in a)/len(a))) if a else -1)' "$TMPD/tap.raw")
    echo "  dial tone on the loudspeaker feed: rms=$rms (vol_speaker 1; restored to ${vol:-?})"
    [ "$rms" -gt 10 ] && pass "media_daemon plays audio after the restore" || fail "no audio after restore (rms=$rms)"
}

run_all() {
    local w
    for w in $(seq 90); do [ "$(healthy)" = yes ] && break; sleep 2; done   # e.g. still booting
    [ "$(healthy)" = yes ] || fail "phone app not healthy before the test"
    deploy
    local sip0 up0 up1 up2 sip1 i
    for i in $(seq 30); do sip0=$(sip_state); case "$sip0" in *OK) break ;; esac; sleep 2; done
    up0=$(uptime_s)
    echo "  before: uptime=${up0}s sip=[$sip0]"

    game_cycle 1
    up1=$(uptime_s)
    [ "$up1" -gt "$up0" ] && pass "no reboot (uptime $up0 -> $up1 s)" || fail "phone rebooted (uptime $up0 -> $up1)"
    for i in $(seq 60); do sip1=$(sip_state); [ "$sip1" = "$sip0" ] && break; sleep 2; done
    assert_eq "$sip0" "$sip1" "SIP registration back to its pre-game state"
    audio_check

    game_cycle 2
    up2=$(uptime_s)
    [ "$up2" -gt "$up1" ] && pass "second run: still no reboot (uptime $up2 s)" || fail "rebooted on second run"
    for i in $(seq 60); do sip1=$(sip_state); [ "$sip1" = "$sip0" ] && break; sleep 2; done
    assert_eq "$sip0" "$sip1" "SIP registration back after the second run"
    ph 'rm -f /tmp/restore-test.nes /tmp/amxrtap'
}

with_phone_lock run_all || exit 1
exit 0
