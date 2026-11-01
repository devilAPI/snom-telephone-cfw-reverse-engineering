#!/bin/sh
# Example: fire an HTTP GET (toggle a light, call a webhook). Edit URL.
URL="http://192.168.178.1/"
wget -q -T 5 -O - "$URL" | head -c 500
echo
echo "done: $URL"
