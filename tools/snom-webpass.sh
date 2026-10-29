#!/bin/sh
# Change the snom web interface password (http_pass + admin_mode_password)
# Deploy to the phone and run via SSH:
#   ssh root@<phone-ip> /snom/snom-webpass.sh <new-password> [current-password]
#
# Two modes:
#   1. HTTP API (preferred) - talks to the phone app on port 8080
#   2. Direct config.xml edit (fallback) - writes plaintext, phone re-hashes on next settings load

set -e

usage() {
    echo "Usage: $0 <new-password> [current-password]"
    echo ""
    echo "Changes the snom web interface password (HTTP + admin mode)."
    echo "If the phone application is running, uses the HTTP settings API."
    echo "Otherwise, edits config.xml directly (requires reboot to apply)."
    exit 1
}

[ -z "$1" ] && usage
NEW_PASS="$1"
CUR_PASS="${2:-}"

CONFIG="/snom/snomconfig/config.xml"

try_http_api() {
    local port="$1"
    local auth=""
    if [ -n "$CUR_PASS" ]; then
        auth="-u admin:${CUR_PASS}"
    else
        auth="-u admin:"
    fi

    # Try to set password via snom HTTP settings API
    result=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 \
        $auth \
        "http://127.0.0.1:${port}/dummy.htm?settings=save&http_pass=${NEW_PASS}&admin_mode_password=${NEW_PASS}" 2>/dev/null)

    [ "$result" = "200" ] && return 0

    # Try POST form submission
    result=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 \
        $auth \
        -d "http_pass=${NEW_PASS}&admin_mode_password=${NEW_PASS}" \
        "http://127.0.0.1:${port}/dummy.htm?settings=save" 2>/dev/null)

    [ "$result" = "200" ] && return 0

    return 1
}

# Try HTTP API on phone app port (8080) then lighttpd port (80)
for port in 8080 80; do
    if try_http_api "$port"; then
        echo "Password changed via HTTP API (port $port)."
        exit 0
    fi
done

# Fallback: direct config.xml edit
echo "Phone application not reachable, editing config.xml directly..."

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: $CONFIG not found"
    exit 1
fi

# Backup
cp "$CONFIG" "${CONFIG}.bak-$(date +%Y%m%d%H%M%S)"

# Replace http_pass value
sed -i "s|<http_pass[^>]*>[^<]*</http_pass>|<http_pass perm=\"\" c=\"1\" trusted=\"true\">${NEW_PASS}</http_pass>|" "$CONFIG"

# Replace admin_mode_password value
sed -i "s|<admin_mode_password[^>]*>[^<]*</admin_mode_password>|<admin_mode_password perm=\"\" c=\"1\" trusted=\"true\">${NEW_PASS}</admin_mode_password>|" "$CONFIG"

echo "Password set in config.xml (plaintext)."
echo "Reboot the phone to apply: reboot"
