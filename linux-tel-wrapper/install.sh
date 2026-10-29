#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/lib/snom-tel-handler"
BIN_DIR="${HOME}/.local/bin"
DESKTOP_FILE="${HOME}/.local/share/applications/snom-tel-handler.desktop"

echo "=== Snom tel: handler installer ==="
echo ""

# Install files
mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$(dirname "$DESKTOP_FILE")"

cp "${SCRIPT_DIR}/tel-handler.sh" "${INSTALL_DIR}/tel-handler.sh"
chmod +x "${INSTALL_DIR}/tel-handler.sh"

if [[ ! -f "${INSTALL_DIR}/tel-handler.ini" ]]; then
    cp "${SCRIPT_DIR}/tel-handler.ini" "${INSTALL_DIR}/tel-handler.ini"
else
    echo "Config already exists, keeping current: ${INSTALL_DIR}/tel-handler.ini"
fi

# Symlink into PATH
ln -sf "${INSTALL_DIR}/tel-handler.sh" "${BIN_DIR}/snom-dial"

# Register as tel: URI handler
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Snom Tel Handler
Exec=${INSTALL_DIR}/tel-handler.sh %u
MimeType=x-scheme-handler/tel;
NoDisplay=true
Terminal=false
EOF

xdg-mime default snom-tel-handler.desktop x-scheme-handler/tel
update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true

echo "Installed to:     ${INSTALL_DIR}/"
echo "Symlink:          ${BIN_DIR}/snom-dial"
echo "Desktop handler:  ${DESKTOP_FILE}"
echo "tel: links will now be handled by this script."
echo ""
echo "Test with:  xdg-open 'tel:+1234567890'"
echo "  or:       snom-dial '+1234567890'"
echo ""
echo "Opening config file for editing..."
sleep 1

# Open config in the user's preferred editor
EDITOR="${VISUAL:-${EDITOR:-}}"
if [[ -n "$EDITOR" ]]; then
    exec "$EDITOR" "${INSTALL_DIR}/tel-handler.ini"
elif command -v xdg-open &>/dev/null; then
    exec xdg-open "${INSTALL_DIR}/tel-handler.ini"
elif command -v nano &>/dev/null; then
    exec nano "${INSTALL_DIR}/tel-handler.ini"
else
    exec vi "${INSTALL_DIR}/tel-handler.ini"
fi
