#!/bin/sh
# Boot a GBA ROM from a URL. $1 = ROM URL. See lib/retro-boot.sh.
exec /snom/cfw/lib/retro-boot.sh gba "$1"
