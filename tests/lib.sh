# Shared test helpers for the CFW feature tests. Source from a test script:
#   . "$(dirname "$0")/lib.sh"
# Needs: ssh, curl, flock on the host. PHONE_IP / PHONE_PW override the defaults.
# The D375 emulator (docs/qemu.md):
#   PHONE_IP=127.0.0.1 PHONE_SSH_PORT=12222 PHONE_PANEL=127.0.0.1:18080 tests/foo.sh

PHONE_IP=${PHONE_IP:-192.168.178.72}
PHONE_PW=${PHONE_PW:-snom375}
PHONE_SSH_PORT=${PHONE_SSH_PORT:-22}
PHONE_PANEL=${PHONE_PANEL:-$PHONE_IP:8080}
PHONE_LOCK=${PHONE_LOCK:-/tmp/claude-1000/snom-phone.lock}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)

# ssh has no password flag; feed it through SSH_ASKPASS (no tty needed).
_askpass=$(mktemp "${TMPDIR:-/tmp}/askpass.XXXXXX")
printf '#!/bin/sh\necho "%s"\n' "$PHONE_PW" > "$_askpass"; chmod 700 "$_askpass"
trap 'rm -f "$_askpass"' EXIT
export SSH_ASKPASS="$_askpass" SSH_ASKPASS_REQUIRE=force

# ph CMD...: run a command on the phone (stdin forwarded), print its stdout.
# The old-ssh banner/warnings on stderr are dropped.
ph() {
    ssh -p "$PHONE_SSH_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o LogLevel=ERROR \
        -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
        root@"$PHONE_IP" "$@" 2>/dev/null
}

# ph_put LOCAL REMOTE: copy a file over ssh (no scp on the phone). Keeps 0755 if set.
ph_put() {
    local mode=644
    [ -x "$1" ] && mode=755
    ph "mkdir -p \"\$(dirname '$2')\" && cat > '$2' && chmod $mode '$2'" < "$1"
}

# with_phone_lock CMD...: run under the shared phone lock (use for disruptive steps).
# CMD may be a shell function of the calling script.
with_phone_lock() {
    mkdir -p "$(dirname "$PHONE_LOCK")"
    ( flock 9; "$@" ) 9>"$PHONE_LOCK"
}

# http PATH: GET http://phone:8080PATH, body to stdout. The panel login is the
# system password (docs/cfw-login.md).
http() { curl -s -m 20 -u "root:$PHONE_PW" "http://$PHONE_PANEL$1"; }

FAILS=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS+1)); exit 1; }
assert_eq() {  # EXPECTED ACTUAL MSG
    if [ "$1" = "$2" ]; then pass "$3"; else echo "  expected: [$1]"; echo "  actual:   [$2]"; fail "$3"; fi
}
assert_contains() {  # HAYSTACK NEEDLE MSG
    case "$1" in *"$2"*) pass "$3" ;; *) echo "  missing [$2] in: $(printf '%s' "$1" | head -c 300)"; fail "$3" ;; esac
}

# wait_phone: until lid and the phone app run again (after a game: restore or
# reboot), then let it settle. Fails after 7.5 minutes.
wait_phone() {
    local i
    for i in $(seq 90); do
        [ "$(ph 'pidof lid >/dev/null && pidof lcsD375 >/dev/null && echo up')" = up ] && { sleep 20; return 0; }
        sleep 5
    done
    return 1
}

# hangup: press and release the red hangup key (code 114), which quits a game.
hangup() { ph 'for v in 0 001 0; do printf "\0\0\0\0\0\0\0\0\001\0\162\0\\$v\0\0\0" > /dev/input/event0; usleep 100000; done'; }
