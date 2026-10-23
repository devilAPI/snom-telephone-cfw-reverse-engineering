#!/usr/bin/env bash
# Back up a running snom D3xx over SSH: device info, /firmware1.pub, the root
# filesystem as a tarball, and (optionally) raw flash partitions.
# Nothing on the phone is modified except a temporary bind mount under /tmp.
#
#   ./tools/fw-pull-from-device.sh <phone-ip> [--raw] [--extract]
#
#   --raw      also dump every MTD partition / the eMMC block device (slow, large)
#   --extract  unpack the rootfs tarball into ./custom-rootfs (with fakeroot)
#
# Old dropbear builds may need legacy algorithms, e.g.:
#   SSH_OPTS="-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa" ./tools/fw-pull-from-device.sh ...
#
# The phone has no scp/sftp guarantee, so everything is streamed through `ssh cat`.
set -euo pipefail
HOST=${1:?phone ip}; shift
RAW=0; EXTRACT=0
for a in "$@"; do
  case "$a" in
    --raw) RAW=1 ;;
    --extract) EXTRACT=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

# shellcheck disable=SC2086
r() { ssh ${SSH_OPTS:-} "root@$HOST" "$@"; }

OUT="backups/$HOST-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
echo "=== Writing backup to $OUT ==="

echo "=== Step 1: Device info ==="
r 'for c in "uname -a" "cat /proc/cmdline" "cat /proc/cpuinfo" "cat /proc/mtd" \
            "cat /proc/partitions" "cat /proc/mounts" "df" "ls -la /" \
            "cat /etc/checksum.md5" "ps"; do
     echo "##### $c"; sh -c "$c" 2>&1; echo; done' > "$OUT/device-info.txt"
echo "  device-info.txt ($(wc -l < "$OUT/device-info.txt") lines)"

echo "=== Step 2: Firmware verification key ==="
r 'cat /firmware1.pub' > "$OUT/firmware1.pub"
openssl rsa -pubin -in "$OUT/firmware1.pub" -noout -text 2>/dev/null | head -1 \
  || echo "  (warning: firmware1.pub did not parse as an RSA public key)"
echo "  md5: $(md5sum < "$OUT/firmware1.pub" | cut -d' ' -f1)"

echo "=== Step 3: Root filesystem ==="
# Bind-mounting / gives a view of the root filesystem only: no /proc, /sys,
# devtmpfs, tmpfs or the writable settings partition stacked on top of it.
r 'M=/tmp/.rootfs-ro; mkdir -p $M && mount -o bind / $M || exit 1
   tar -cf - -C $M .; rc=$?
   umount $M; rmdir $M; exit $rc' | gzip -9 > "$OUT/rootfs.tar.gz"
echo "  rootfs.tar.gz: $(stat -c%s "$OUT/rootfs.tar.gz") bytes, $(tar -tzf "$OUT/rootfs.tar.gz" | wc -l) entries"

if [ "$RAW" -eq 1 ]; then
  echo "=== Step 4: Raw flash partitions ==="
  mkdir -p "$OUT/raw"
  # MTD (raw NAND/NOR): /proc/mtd lines look like  mtd0: 00040000 00020000 "u-boot"
  for dev in $(r 'sed -n "s/^\(mtd[0-9]*\):.*/\1/p" /proc/mtd 2>/dev/null'); do
    name=$(r "sed -n 's/^$dev:.*\"\(.*\)\"/\1/p' /proc/mtd")
    r "cat /dev/$dev" > "$OUT/raw/$dev-${name:-unnamed}.bin"
    echo "  $dev ($name): $(stat -c%s "$OUT/raw/$dev-${name:-unnamed}.bin") bytes"
  done
  # eMMC: dump the whole device, partitions can be carved out later
  for dev in $(r 'ls /dev | grep -E "^mmcblk[0-9]+$"' || true); do
    r "cat /dev/$dev" > "$OUT/raw/$dev.img"
    echo "  $dev: $(stat -c%s "$OUT/raw/$dev.img") bytes"
  done
fi

(cd "$OUT" && sha256sum -- * raw/* 2>/dev/null > SHA256SUMS || true)

if [ "$EXTRACT" -eq 1 ]; then
  echo "=== Extracting into custom-rootfs/ ==="
  if [ -e custom-rootfs ]; then
    echo "  custom-rootfs/ already exists; refusing to overwrite. Move it away first." >&2
    exit 1
  fi
  mkdir custom-rootfs
  if command -v fakeroot >/dev/null 2>&1; then
    fakeroot -s custom-rootfs/.fakeroot \
      tar -xzf "$OUT/rootfs.tar.gz" -C custom-rootfs --numeric-owner
  else
    echo "  (warning: no fakeroot -- dev nodes and ownership will be lost)" >&2
    tar -xzf "$OUT/rootfs.tar.gz" -C custom-rootfs --numeric-owner
  fi
  echo "  done"
fi

echo ""
echo "Backup complete: $OUT"
echo "Contains phone-specific data (SSH host keys, root credentials) -- do not commit."
