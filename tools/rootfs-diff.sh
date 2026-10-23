#!/usr/bin/env bash
# List what a custom rootfs changes compared to a stock one.
# Use it to recover the modifications baked into a firmware pulled off a phone.
#
#   ./tools/rootfs-diff.sh <stock-rootfs-dir> <custom-rootfs-dir>
#
# Stock rootfs: ./tools/fw-unpack.sh original_firmware/snomD375-<ver>-SIP-r.bin keys/snomD3xx-firmware1.pub decrypted/snomD375-<ver>-SIP-r/rootfs
# Compare against the SAME stock version the custom image was built from,
# otherwise every vendor change shows up too.
set -euo pipefail
A=${1:?stock rootfs dir}; B=${2:?custom rootfs dir}
export LC_ALL=C   # diff output is parsed below

echo "# rootfs diff: $A -> $B"
echo "# A = only in custom (added), D = only in stock (removed), M = content/type differs"
diff -rq --no-dereference "$A" "$B" 2>/dev/null \
  | grep -v '/\.fakeroot' \
  | sed -E \
      -e "s|^Only in $B/?([^:]*): (.*)|A /\1/\2|" \
      -e "s|^Only in $A/?([^:]*): (.*)|D /\1/\2|" \
      -e "s|^Files $A/(.*) and $B/.* differ$|M /\1|" \
      -e "s|^File $A/(.*) is .* while file $B/.*|M /\1|" \
      -e 's|//+|/|g' \
  | sort -k2 || true
