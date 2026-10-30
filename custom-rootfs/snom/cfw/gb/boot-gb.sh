#!/bin/sh
# Boot a GB/GBC ROM from a URL. $1 = ROM URL. See lib/retro-boot.sh.
exec /snom/cfw/lib/retro-boot.sh gb "$1"
