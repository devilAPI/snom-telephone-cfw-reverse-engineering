#!/bin/sh
# Example: Navidrome player, next track (docs/navidrome.md). Copy to /snom/cfw-data/scripts/
# and put it on a key in the panel (Scripts card) for a one-press control.
/snom/cfw/navidrome/player.sh next | sed -n "s/^\\(state\\|title\\|error\\)=/\\1: /p"
