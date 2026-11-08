#!/usr/bin/env bash
# Navidrome player test (docs/navidrome.md). Needs docker, ffmpeg and curl on this PC.
# Starts a throwaway Navidrome in docker with a few generated sine tones (two artists,
# one with "&" in its name, titles with "<n>"), points the phone at it through the panel,
# checks the setup errors, the phone menus, search, play / next / pause / resume / prev /
# stop, the speaker's player channel, and hostile input. The phone's own Navidrome config
# is saved first and put back at the end. Tones play at volume 22 (about 5 %).
#   NODEPLOY=1 tests/navidrome.sh   skips the deploy step
set -u
. "$(dirname "$0")/lib.sh"
R=$REPO/rootfs/d375/snom/cfw
TMP=$(mktemp -d)
CT=nd-cfwtest-$$
NDPORT=45333
PCIP=$(ip route get "$PHONE_IP" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
cleanup() {
    ph '/snom/cfw/navidrome/player.sh stop >/dev/null 2>&1; rm -f /snom/cfw-data/navidrome/conf' >/dev/null
    [ -s "$TMP/conf.bak" ] && ph 'mkdir -p /snom/cfw-data/navidrome && cat > /snom/cfw-data/navidrome/conf && chmod 600 /snom/cfw-data/navidrome/conf' < "$TMP/conf.bak"
    # the container writes as root: let it delete its own files
    docker exec "$CT" sh -c 'rm -rf /data/* /data/.[!.]*' >/dev/null 2>&1
    docker rm -f "$CT" >/dev/null 2>&1
    rm -rf "$TMP" "$_askpass"
}
trap cleanup EXIT
[ -n "$PCIP" ] || fail "no route to the phone"

# --- a small library and a server ---
mkdir -p "$TMP/music" "$TMP/data"
i=0
for ar in "Test Artist A" "Zeta & Sons"; do
    mkdir -p "$TMP/music/$ar/Album One"
    for t in 1 2; do
        i=$((i + 1))
        ffmpeg -nostdin -v error -f lavfi -i "sine=frequency=$((300 + i * 100)):duration=$((10 + t * 4))" -ac 2 -ar 44100 -b:a 128k \
            -metadata artist="$ar" -metadata album="Album One" -metadata title="Tone $i <$t>" -metadata track=$t \
            "$TMP/music/$ar/Album One/$t.mp3" || fail "ffmpeg"
    done
done
docker run -d --name "$CT" -p "$NDPORT:4533" -v "$TMP/music:/music:ro" -v "$TMP/data:/data" \
    -e ND_SCANSCHEDULE=0 deluan/navidrome:latest >/dev/null || fail "docker run navidrome"
for _ in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$NDPORT/ping" && break; sleep 1; done
curl -s -X POST -H 'Content-Type: application/json' -d '{"username":"cfwtest","password":"cfwtestpw"}' \
    "http://127.0.0.1:$NDPORT/auth/createAdmin" >/dev/null
docker exec "$CT" /app/navidrome scan >/dev/null 2>&1
pass "test Navidrome on $PCIP:$NDPORT"

deploy() {
    for f in navidrome/navplay navidrome/player.sh navidrome/nd-lib.sh intercom/spkstream intercom/speaker.sh \
             intercom/amxr-mod.sh cgi-bin/navidrome panel.d/92-navidrome.html phone-menu.d/32-navidrome; do
        ph_put "$R/$f" "/snom/cfw/$f"
    done
}
ph 'cat /snom/cfw-data/navidrome/conf 2>/dev/null' > "$TMP/conf.bak"
[ -n "${NODEPLOY:-}" ] || with_phone_lock deploy

post() { curl -s -m 60 -u "root:$PHONE_PW" "http://$PHONE_PANEL/cgi-bin/navidrome" "$@"; }
menu() { ph "wget -q -O - 'http://127.0.0.1:8081/cgi-bin/navidrome?a=phone$1'"; }
jv() { sed -n "s/.*\"$1\":\"\\{0,1\\}\\([^\",}]*\\).*/\\1/p" <<<"$2"; }

# --- setup ---
ph 'rm -f /snom/cfw-data/navidrome/conf'
assert_contains "$(menu '')" 'Not set up' "phone menu says: not set up"
assert_contains "$(post -d 'a=save' --data-urlencode 'url=https://x' -d 'user=u&pass=p')" 'https is not supported' "https refused"
assert_contains "$(post -d 'a=save' --data-urlencode "url=http://$PCIP:$NDPORT" -d 'user=cfwtest&pass=wrong')" 'Wrong username or password' "wrong password reported"
out=$(post -d 'a=save' --data-urlencode "url=http://$PCIP:$NDPORT" -d 'user=cfwtest&pass=cfwtestpw&bitrate=96&vol=22')
assert_contains "$out" '"ok":true' "save with the right password"
case "$(ph 'cat /snom/cfw-data/navidrome/conf')" in *cfwtestpw*) fail "password stored in clear" ;; *) pass "password not stored" ;; esac
assert_eq "-rw-------" "$(ph 'ls -l /snom/cfw-data/navidrome/conf' | cut -c1-10)" "config readable by root only"

# --- menus ---
m=$(menu '&v=artists')
assert_contains "$m" 'Zeta &amp; Sons (1)' "artists, & escaped"
id=$(sed -n 's/.*v=artist&amp;id=\([A-Za-z0-9]*\).*/\1/p' <<<"$m" | head -n 1)
al=$(menu "&v=artist&id=$id" | sed -n 's/.*v=album&amp;id=\([A-Za-z0-9]*\).*/\1/p' | head -n 1)
m=$(menu "&v=album&id=$al")
assert_contains "$m" '&lt;1&gt;' "album tracks, < > escaped"
assert_eq 3 "$(grep -c '<MenuItem' <<<"$m")" "album: Play all + 2 tracks"
assert_contains "$(menu '&v=results&q=Zeta%20%26%20Sons')" 'Album: Album One - Zeta &amp; Sons' "search on the phone"
assert_contains "$(menu '&v=search')" '<IPPhoneInput' "search input"
assert_contains "$(post -d 'a=search' --data-urlencode 'q=Tone')" '"title":"Tone 1 <1>"' "search in the panel"
for q in '&do=%3Breboot' '&v=album&id=%24(id)' '&v=..%2F..' '&do=play&src=x%3Bid'; do
    assert_contains "$(menu "$q")" '<IPPhoneMenu' "hostile query [$q] handled"
done
assert_eq "" "$(ph 'ls /tmp/pwned 2>/dev/null')" "no command injection"

# --- playing (the speaker: take the lock) ---
play_test() {
    out=$(post -d "a=play&src=album&id=$al&i=0")
    assert_contains "$out" '"state":"playing"' "play an album"
    sleep 4
    s=$(post -d 'a=status'); p1=$(jv pos "$s")
    [ "${p1:-0}" -ge 1 ] && pass "position moves ($p1 s)" || fail "position does not move: $s"
    assert_contains "$(ph 'K=$(cat /tmp/speaker/token); wget -q -O - "http://127.0.0.1:8091/status?k=$K"')" '"player":{"playing":1' "speaker player channel plays"
    s=$(post -d 'a=ctl&do=next'); assert_eq 1 "$(jv idx "$s")" "next"
    sleep 4
    s=$(post -d 'a=ctl&do=pause'); assert_eq paused "$(jv state "$s")" "pause"; pp=$(jv pos "$s")
    assert_eq "" "$(ph 'pidof navplay')" "nothing decodes while paused"
    s=$(post -d 'a=ctl&do=resume'); assert_eq playing "$(jv state "$s")" "resume"
    grep -q "from ${pp}s" <<<"$(ph 'tail -n 3 /tmp/navidrome/log')" && pass "resumed at ${pp} s" || fail "resume position (paused at $pp)"
    s=$(post -d 'a=ctl&do=prev'); assert_eq 1 "$(jv idx "$s")" "prev after > 5 s: start of the same track"
    s=$(post -d 'a=ctl&do=stop'); assert_eq stopped "$(jv state "$s")" "stop"
    sleep 1
    assert_eq "" "$(ph 'pidof navplay')" "no navplay left"
    assert_contains "$(ph 'K=$(cat /tmp/speaker/token); wget -q -O - "http://127.0.0.1:8091/status?k=$K"')" '"player":{"playing":0' "speaker player channel stopped"
    # the end of the queue: the last track, played to the end
    post -d "a=play&src=album&id=$al&i=1" >/dev/null
    sleep 25
    s=$(post -d 'a=status'); assert_eq stopped "$(jv state "$s")" "stops at the end of the queue"
    grep -q "end of the queue" <<<"$(ph 'tail -n 2 /tmp/navidrome/log')" && pass "log: end of the queue" || fail "log"
}
with_phone_lock play_test || exit 1
echo "ALL NAVIDROME TESTS PASSED"
