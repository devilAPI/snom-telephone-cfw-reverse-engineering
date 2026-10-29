#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
INI_FILE="${SCRIPT_DIR}/tel-handler.ini"

if [[ ! -f "$INI_FILE" ]]; then
    echo "Error: Config file not found: $INI_FILE" >&2
    exit 1
fi

parse_ini() {
    local key="$1" section="$2" file="$3"
    sed -n "/^\[${section}\]/,/^\[/p" "$file" \
        | grep -E "^${key}\s*=" \
        | head -1 \
        | sed 's/^[^=]*=\s*//' \
        | sed 's/\s*$//' \
        | sed 's/\s*;.*$//'
}

PHONE_HOST="$(parse_ini host phone "$INI_FILE")"
PHONE_USER="$(parse_ini username phone "$INI_FILE")"
PHONE_PASS="$(parse_ini password phone "$INI_FILE")"
USE_HTTPS="$(parse_ini https phone "$INI_FILE")"
OUTGOING_URI="$(parse_ini outgoing_uri dialing "$INI_FILE")"
STRIP_CHARS="$(parse_ini strip_chars dialing "$INI_FILE")"
DIAL_PREFIX="$(parse_ini dial_prefix dialing "$INI_FILE")"
NOTIFY="$(parse_ini notify notifications "$INI_FILE")"
NOTIFY_TIMEOUT="$(parse_ini notify_timeout notifications "$INI_FILE")"

STRIP_CHARS="${STRIP_CHARS:-[\\s\\-\\(\\)]}"
NOTIFY="${NOTIFY:-true}"
NOTIFY_TIMEOUT="${NOTIFY_TIMEOUT:-5000}"

if [[ -z "$PHONE_HOST" ]]; then
    echo "Error: phone host not configured in $INI_FILE" >&2
    exit 1
fi

PROTOCOL="http"
if [[ "$USE_HTTPS" == "true" ]]; then
    PROTOCOL="https"
fi

RAW_INPUT="${1:-}"
if [[ -z "$RAW_INPUT" ]]; then
    echo "Usage: $0 <tel:+1234567890>" >&2
    exit 1
fi

NUMBER="$RAW_INPUT"
NUMBER="${NUMBER#tel:}"
NUMBER="${NUMBER#TEL:}"
NUMBER="${NUMBER#Tel:}"

if [[ -n "$STRIP_CHARS" ]]; then
    NUMBER="$(echo "$NUMBER" | sed "s/${STRIP_CHARS}//g")"
fi

if [[ -n "$DIAL_PREFIX" ]]; then
    NUMBER="${DIAL_PREFIX}${NUMBER}"
fi

if [[ -z "$NUMBER" ]]; then
    echo "Error: no phone number provided" >&2
    exit 1
fi

send_notify() {
    if [[ "$NOTIFY" == "true" ]] && command -v notify-send &>/dev/null; then
        notify-send -t "$NOTIFY_TIMEOUT" -i call-start "Snom Dialer" "$1"
    fi
}

URL="${PROTOCOL}://${PHONE_HOST}/command.htm"
PARAMS="number=${NUMBER}"
if [[ -n "$OUTGOING_URI" ]]; then
    PARAMS="${PARAMS}&outgoing_uri=${OUTGOING_URI}"
fi

CURL_ARGS=(
    --silent
    --max-time 10
    --user "${PHONE_USER}:${PHONE_PASS}"
    --digest
)

if [[ "$USE_HTTPS" == "true" ]]; then
    CURL_ARGS+=(--insecure)
fi

echo "Dialing ${NUMBER} via ${PHONE_HOST}..."
send_notify "Dialing ${NUMBER}..."

HTTP_CODE="$(curl "${CURL_ARGS[@]}" -o /dev/null -w '%{http_code}' "${URL}?${PARAMS}" 2>/dev/null)" || {
    echo "Error: could not connect to phone at ${PHONE_HOST}" >&2
    send_notify "Failed to connect to phone"
    exit 1
}

if [[ "$HTTP_CODE" == "200" ]]; then
    echo "Call initiated successfully"
    send_notify "Call to ${NUMBER} initiated"
elif [[ "$HTTP_CODE" == "401" ]]; then
    echo "Error: authentication failed (HTTP 401)" >&2
    send_notify "Authentication failed"
    exit 1
else
    echo "Error: phone returned HTTP ${HTTP_CODE}" >&2
    send_notify "Dial failed (HTTP ${HTTP_CODE})"
    exit 1
fi
