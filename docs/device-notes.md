# snom D375 device notes

Confirmed facts about the hardware and software. Most of this can be filled in
from `backups/<ip>-<ts>/device-info.txt`, which `fw-pull-from-device.sh`
produces. Only write down what has actually been seen on a device. Mark
anything else as unconfirmed.

## Identification

| | |
|---|---|
| Firmware version (base of custom image) | 10.1.64.17 SIP (`snom/version`), per `original_firmware/`. Check against the phone |
| Kernel | Linux 2.6.27.47, ARM, legacy uImage, load/entry 0x0D000000 (from `boot/uImage` in the stock image) |
| CPU / SoC (`/proc/cpuinfo`) | _TODO_ |
| Userland | _TODO (busybox version?)_ |

## Storage and partitions

Raw NAND/MTD. The mapping below comes from the D3xx entries in the stock
`/etc/init.d/rcS`. Confirm it against `/proc/mtd` in `device-info.txt`:

| Device | Use (per rcS) |
|---|---|
| `mtd0` | boot1 (reflashed by `postSystemUpdate.sh` only on bad ECC) |
| `mtd1` | U-Boot (`/boot/u-boot.bin`) |
| `mtdblock4` | rescue filesystem (used for "advanced" system updates) |
| `mtdblock5` | `/protected`, jffs2, mounted read-only (`advancedUpdateVersion`, device data) |
| `mtd6` | kernel (`/boot/uImage`) |
| `mtdblock7` | root filesystem |

```
TODO: paste /proc/mtd and /proc/mounts from the phone
```

- Root filesystem: read-only in normal operation (`mount -o remount,rw /` works as root)
- Phone settings live **on the rootfs** in `/snom/snomconfig/` (`config.xml`), so a pulled rootfs contains them
- `/var` is a symlink to `/tmp/var` (tmpfs). `/dev` is populated by `mdev -s` on the rootfs

## Boot

- Kernel cmdline: _TODO_
- Init: busybox (`/linuxrc` → `bin/busybox`), `etc/inittab` → `etc/init.d/rcS` (one large script: mounts, cleanup, update handling, app start via `/snom/start.sh`)
- At every boot rcS deletes `/update`, `/boot/*`, `/update.bin`, `/snom_new`, `/snom_old`
- `md5Check`: verifies `etc/checksum.md5` and halts to a console shell on a mismatch, but only in the factory filesystem-test start mode, not a normal boot
- Where our SSH server is started: _TODO (see root-access.md)_

## Firmware update

- Verification key: `/firmware1.pub` (RSA-1024)
- Checksums: `/etc/checksum.md5` covers `firmware1.pub` and ~9250 other files. Not checked in a normal boot (see Boot)
- Update flow: see [firmware-format.md](firmware-format.md#how-the-phone-installs-an-image-etcinitdrcs)
- Update via the web UI with an HTTP URL: works for custom images
