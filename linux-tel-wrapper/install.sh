#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HANDLER_SCRIPT="${SCRIPT_DIR}/tel-handler.sh"
DESKTOP_FILE="${HOME}/.local/share/applications/snom-tel-handler.desktop"

if [[ ! -x "$HANDLER_SCRIPT" ]]; then
    chmod +x "$HANDLER_SCRIPT"
fi

mkdir -p "$(dirname "$DESKTOP_FILE")"

cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Snom Tel Handler
Exec=${HANDLER_SCRIPT} %u
MimeType=x-scheme-handler/tel;
NoDisplay=true
Terminal=false
EOF

xdg-mime default snom-tel-handler.desktop x-scheme-handler/tel

echo "Installed tel: URI handler"
echo "Desktop file: ${DESKTOP_FILE}"
echo ""
echo "Edit ${SCRIPT_DIR}/tel-handler.ini to configure your phone."
echo "Test with: xdg-open 'tel:+1234567890'"
