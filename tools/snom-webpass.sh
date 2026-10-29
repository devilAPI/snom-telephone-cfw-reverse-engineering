#!/bin/sh
# Change the snom D815(W) web interface password via SSH.
#
# Run from your workstation:
#   ssh root@<phone-ip> /snom/snom-webpass.sh <new-password>
#
# Or deploy once and call later:
#   scp tools/snom-webpass.sh root@<phone-ip>:/snom/snom-webpass.sh
#   ssh root@<phone-ip> /snom/snom-webpass.sh myNewPassword
#
# What it does:
#   1. Writes the new password (plaintext) into config.xml for both
#      http_pass and admin_mode_password
#   2. Clears setting_server and sets update_policy=never so a provisioning
#      server (e.g. Webex) cannot overwrite the password on next boot
#   3. Restarts the phone application (lcsD815) so the new password
#      takes effect immediately — no full reboot needed
#   4. Verifies the new password works via HTTP Digest auth

set -e

CONFIG="/snom/snomconfig/config.xml"

usage() {
    echo "Usage: $0 <new-password>"
    echo ""
    echo "Changes the snom web interface password (HTTP + admin mode)."
    echo "Must be run as root on the phone via SSH."
    exit 1
}

[ -z "$1" ] && usage
NEW_PASS="$1"

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: $CONFIG not found"
    exit 1
fi

# Read the current http_user from config.xml (default: admin)
HTTP_USER="admin"
u=$(sed -n 's|.*<http_user[^>]*>\([^<]*\)</http_user>.*|\1|p' "$CONFIG")
[ -n "$u" ] && HTTP_USER="$u"

echo "Changing web password for user '${HTTP_USER}'..."

# Backup current config
cp "$CONFIG" "${CONFIG}.bak-$(date +%Y%m%d%H%M%S)"

# Set new password (plaintext — lcsD815 accepts it directly)
sed -i "s|<http_pass[^>]*>[^<]*</http_pass>|<http_pass perm=\"RW\" c=\"1\" trusted=\"true\">${NEW_PASS}</http_pass>|" "$CONFIG"
sed -i "s|<admin_mode_password[^>]*>[^<]*</admin_mode_password>|<admin_mode_password perm=\"RW\" c=\"1\" trusted=\"true\">${NEW_PASS}</admin_mode_password>|" "$CONFIG"

# Prevent provisioning server from overwriting our changes
sed -i "s|<setting_server[^>]*>[^<]*</setting_server>|<setting_server perm=\"RW\" c=\"1\" trusted=\"true\"></setting_server>|" "$CONFIG"
sed -i "s|<update_policy[^>]*>[^<]*</update_policy>|<update_policy perm=\"RW\" c=\"1\" trusted=\"true\">never</update_policy>|" "$CONFIG"

echo "Config updated. Restarting phone application..."

# Restart lcsD815 (it gets auto-restarted by init)
kill -9 $(pidof lcsD815) 2>/dev/null || true

# Wait for lcsD815 HTTP server to come back (takes ~15-30s after kill)
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 3
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://127.0.0.1:80/" 2>/dev/null)
    if [ "$CODE" != "000" ] && [ "$CODE" != "" ]; then
        break
    fi
done

# Verify the new password works
VERIFY=$(curl -s -o /dev/null -w "%{http_code}" --digest -u "${HTTP_USER}:${NEW_PASS}" "http://127.0.0.1:80/" 2>/dev/null)
if [ "$VERIFY" = "200" ]; then
    echo "Password changed successfully. Web UI accessible with new password."
else
    echo "WARNING: Password set in config but HTTP verify returned $VERIFY."
    echo "The phone may still be starting up — try accessing the web UI in a browser."
fi
