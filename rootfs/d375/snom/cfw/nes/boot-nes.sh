#!/bin/sh
# Boot a NES ROM from a URL. $1 = ROM URL (or --pick SID IDX). See lib/retro-boot.sh.
exec /snom/cfw/lib/retro-boot.sh nes "$@"
