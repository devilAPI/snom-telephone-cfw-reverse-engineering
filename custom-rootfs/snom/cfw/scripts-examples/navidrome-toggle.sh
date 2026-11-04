#!/bin/sh
# Example: Navidrome player, play or pause (docs/navidrome.md). Copy to /snom/cfw-data/scripts/
# and put it on a key in the panel (Scripts card) for a one-press control.
/snom/cfw/navidrome/player.sh toggle | sed -n "s/^\\(state\\|title\\|error\\)=/\\1: /p"
