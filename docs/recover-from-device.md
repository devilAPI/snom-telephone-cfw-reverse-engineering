# Rebuilding the project from a running phone

Use this when the phone runs a custom image but the build inputs
(`custom-rootfs/`, `custom-key/`, the `.bin`) are gone.

What you can and can't get back:

| Item | Recoverable? | How |
|---|---|---|
| Root filesystem (all changes we made) | yes | tar it over SSH |
| `/firmware1.pub` (custom public key) | yes | `cat` over SSH |
| Raw flash (bootloader, kernel, settings) | yes, as a backup | dump `/dev/mtd*` or `/dev/mmcblk*` |
| The exact original `.bin` | no | not stored on the phone after flashing. Rebuild it from the rootfs + stock `update/` and `boot/` |
| Custom **private** key | **no** | never on the phone. Generate a new one and rekey |

## Steps

### 1. Pull everything

```sh
./tools/fw-pull-from-device.sh <phone-ip> --raw --extract
```

This creates `backups/<ip>-<timestamp>/`:

- `device-info.txt`: uname, kernel cmdline, `/proc/mtd`, `/proc/partitions`,
  mounts, `df`, processes, `/etc/checksum.md5`
- `firmware1.pub`: the key the phone accepts updates with right now
- `rootfs.tar.gz`: the root filesystem
- `raw/`: partition dumps (with `--raw`)
- `SHA256SUMS`

With `--extract`, it also unpacks the rootfs into `custom-rootfs/` under
`fakeroot` (state saved to `custom-rootfs/.fakeroot`). That's the layout
`build-custom-firmware.sh` expects.

#### How the rootfs is captured

On the phone, the script bind-mounts `/` onto `/tmp/.rootfs-ro` and tars that
view. A bind mount of `/` shows only the root filesystem itself, without the
`/proc`, `/sys`, `/dev` (devtmpfs), `/tmp` and settings mounts stacked on top
of it. You get what the image installed, plus the static `/dev` nodes, and
none of the runtime state. The bind mount is removed afterwards.

To do it by hand from your SSH session:

```sh
# on the phone
mkdir /tmp/r && mount -o bind / /tmp/r
# on your PC
ssh root@<ip> 'tar -cf - -C /tmp/r .' | gzip > rootfs.tar.gz
# on the phone
umount /tmp/r && rmdir /tmp/r
```

> The tarball is a **running** system. If anything on the rootfs was modified
> by hand after flashing (e.g. a `/firmware1.pub` swap), that change is in it.
> Check with `rootfs-diff.sh` (step 3).

### 2. Restore what the phone deleted

A stock `.bin` is just the rootfs tarball, but the phone deletes `/update`
and `/boot/*` on every boot (see [firmware-format.md](firmware-format.md#how-the-phone-installs-an-image-etcinitdrcs)).
**Without `update/systemUpdate`, the phone would unpack your image into
`/snom` and break the phone app.** Copy those parts back from the stock image
of the same version, and swap your personal `snom/snomconfig` (SIP accounts!)
for the stock defaults:

```sh
./tools/fw-unpack.sh original_firmware/snomD375-10.1.64.17-SIP-r.bin keys/snomD3xx-firmware1.pub \
    decrypted/snomD375-10.1.64.17-SIP-r/rootfs
./tools/prepare-pulled-rootfs.sh decrypted/snomD375-10.1.64.17-SIP-r/rootfs
```

The script also runs `md5sum -c etc/checksum.md5`, which the phone enforces at boot.

### 3. Save the public key

```sh
cp backups/<ip>-<ts>/firmware1.pub keys/custom-old-firmware1.pub
```

It's public and safe to commit. It can decrypt any image built with the
lost private key, if one ever turns up again.

### 4. Work out what the old session changed

The base version is in `custom-rootfs/snom/version`. Diff against that stock rootfs:

```sh
./tools/rootfs-diff.sh decrypted/snomD375-10.1.64.17-SIP-r/rootfs custom-rootfs
```

Expect noise from runtime state (`dev/`, `etc/random-seed`, `etc/cron.d`).

`A` = added, `M` = modified, `D` = removed. Write the findings into
[root-access.md](root-access.md) and [device-notes.md](device-notes.md).

### 5. Rekey and rebuild

The private key is gone, so generate a new one. The build script also writes it
into `custom-rootfs/firmware1.pub`:

```sh
./tools/build-custom-firmware.sh
```

Install the new public key on the phone and check it
([signing-keys.md](signing-keys.md#rekeying-a-phone-new-key-or-lost-key)). Then
flash the rebuilt image as a test: if the phone boots and SSH still works, the
whole pipeline is confirmed end to end.

### 6. Back up the new private key

Copy `custom-key/` somewhere safe outside the repo **now**.

## Don't commit backups

`backups/` is gitignored. It holds SSH host keys, root credentials, and with
`--raw` the settings partition (SIP account passwords, provisioning URLs).
