#!/bin/sh
# Example: Navidrome player, previous track (or the start of this one) (docs/navidrome.md). Copy to /snom/cfw-data/scripts/
# and put it on a key in the panel (Scripts card) for a one-press control.
/snom/cfw/navidrome/player.sh prev | sed -n "s/^\\(state\\|title\\|error\\)=/\\1: /p"
