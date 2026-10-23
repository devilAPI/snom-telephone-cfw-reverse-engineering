#!/usr/bin/env bash
# Turn a rootfs pulled off a running phone back into something that can be
# packed as a firmware image, by restoring the parts the phone throws away.
#
#   ./tools/prepare-pulled-rootfs.sh <stock-rootfs> [custom-rootfs]
#
# <stock-rootfs> must be the unpacked stock image of the SAME version the phone
# runs (compared via snom/version), e.g. decrypted/snomD375-10.1.64.17-SIP-r/rootfs
#
# Why (see /etc/init.d/rcS of the stock image):
#  - setUpFileSystems runs `rm -rf /update /boot/* ...` on every boot. Without
#    update/systemUpdate the phone treats an image as an "Application Update"
#    and unpacks the WHOLE tarball into /snom -- the phone app is gone after that.
#    boot/ holds uImage + u-boot.bin, flashed only when they differ from flash.
#  - snom/snomconfig on a running phone holds its settings (config.xml with SIP
#    credentials etc.). Ship the stock defaults instead; extracting an update
#    over / does not delete the phone's own config.xml.
#  - md5Check verifies /etc/checksum.md5 (factory filesystem-test mode only, not
#    a normal boot); we keep it consistent so images pass that check too.
set -euo pipefail
STOCK=${1:?stock rootfs dir}; CUSTOM=${2:-custom-rootfs}

for d in "$STOCK" "$CUSTOM"; do
  [ -f "$d/.fakeroot" ] || { echo "FAIL: $d/.fakeroot missing (unpack with fakeroot)"; exit 1; }
done

sv=$(cat "$STOCK/snom/version"); cv=$(cat "$CUSTOM/snom/version")
if [ "$sv" != "$cv" ] && [ "${FORCE:-0}" != 1 ]; then
  echo "FAIL: stock is $sv but custom rootfs is $cv. Use the matching stock image (or FORCE=1)."
  exit 1
fi
echo "=== Version $cv ==="

echo "=== Restoring update/, boot/ and snom/snomconfig from stock ==="
fakeroot -i "$CUSTOM/.fakeroot" -s "$CUSTOM/.fakeroot" rm -rf "$CUSTOM/snom/snomconfig"
# tar between the two fakeroot sessions keeps stock ownership (root / snom user)
(cd "$STOCK" && fakeroot -i .fakeroot tar -cf - update boot snom/snomconfig) \
  | fakeroot -i "$CUSTOM/.fakeroot" -s "$CUSTOM/.fakeroot" \
      tar -xpf - -C "$CUSTOM" --numeric-owner
ls "$CUSTOM/update" "$CUSTOM/boot"

# The phone also deletes these after installing an image (cleanUpRootfs,
# postSystemUpdate.sh updateOpenVPNBinary). Ship them like stock does.
echo "=== Restoring clean.rootfs and usr/container from stock ==="
(cd "$STOCK" && fakeroot -i .fakeroot tar -cf - clean.rootfs usr/container) \
  | fakeroot -i "$CUSTOM/.fakeroot" -s "$CUSTOM/.fakeroot" \
      tar -xpf - -C "$CUSTOM" --numeric-owner

# Runtime state that rcS, mdev or DHCP recreate on every boot. Stock images
# don't contain it, so neither should ours.
echo "=== Removing runtime leftovers ==="
extra_dev=$(LC_ALL=C comm -13 <(cd "$STOCK" && find dev -mindepth 1 | LC_ALL=C sort) \
                     <(cd "$CUSTOM" && find dev -mindepth 1 | LC_ALL=C sort))
echo "  $(echo "$extra_dev" | grep -c .) extra dev/ entries"
(cd "$CUSTOM" && printf '%s\n' $extra_dev etc/resolv.conf etc/random-seed etc/cron.d \
    snom/bt-avk-fifo tmp var protected \
  | fakeroot -i .fakeroot -s .fakeroot xargs -r rm -rf)

# sshd ignores private host keys other users can read.
for k in "$CUSTOM"/etc/ssh/ssh_host_*_key; do
  [ -f "$k" ] && fakeroot -i "$CUSTOM/.fakeroot" -s "$CUSTOM/.fakeroot" chmod 600 "$k"
done

echo "=== Checking /etc/checksum.md5 ==="
if (cd "$CUSTOM" && md5sum -c --quiet etc/checksum.md5); then
  echo "  all checksums OK"
else
  echo "FAIL: the files above don't match etc/checksum.md5. Fix the file or its entry before building."
  exit 1
fi
echo "Done. Build with ./tools/build-custom-firmware.sh"
