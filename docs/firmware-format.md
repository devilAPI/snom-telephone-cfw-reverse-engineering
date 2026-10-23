# snom v10 firmware image format

This applies to the snom v10 D1xx/D3xx/D7xx/D8xx line. Both `tools/fw-unpack.sh`
and `tools/build-custom-firmware.sh` implement it. It mirrors what the phone's
`verifySoftwareUpdateFile()` does.

Sources: the [encrypted.at D785 write-up](https://www.encrypted.at/remote-root-shell-on-a-snom-d785-voip-phone-using-openvpn-configuration-files/)
and forum.coredump.ch/t/235. Confirmed working on the D375 by round-tripping
our own images.

## Layout

```
offset 0     128 bytes   signature   RSA-1024 PKCS#1 v1.5, SHA-1 over bytes 128..EOF
offset 128   128 bytes   key block   RSA "signed" AES passphrase (recover with verify-recover)
offset 256   ...         payload     OpenSSL "Salted__" AES-128-CBC, MD5 KDF, of rootfs.tar.gz
```

Both RSA blocks are 128 bytes because the key is 1024 bits. A different key
size changes the offsets, and the phone's parser almost certainly assumes 128.
Keep custom keys at **1024 bits**.

## Verification on the phone

1. Check `signature` over `key block || payload` against `/firmware1.pub`.
2. `pkeyutl -verifyrecover` the key block with the same public key to get the
   AES passphrase. The "encryption" is really a signature, so anyone holding
   the public key can decrypt an image.
3. `openssl enc -d -aes-128-cbc -md md5` the payload with that passphrase.
4. Unpack the resulting `tar.gz` as the new root filesystem.

Equivalent host commands:

```sh
dd if=img.bin bs=128 count=1 of=sig
dd if=img.bin bs=128 skip=1 | openssl dgst -sha1 -verify firmware1.pub -signature sig
dd if=img.bin bs=128 skip=1 count=1 | openssl pkeyutl -verifyrecover -pubin -inkey firmware1.pub -out pass
dd if=img.bin bs=128 skip=2 | openssl enc -aes-128-cbc -d -md md5 -kfile pass | tar -tz
```

OpenSSL 3 prints `*** WARNING : deprecated key derivation used.` for `-md md5`
without `-pbkdf2`. You can ignore it: the phone expects exactly that KDF.

## Payload: the rootfs tarball

- gzip-compressed tar, with paths relative to `/` and no leading `./`. The
  build script writes it with `find | sed 's|^\./||'`.
- Ownership and device nodes matter. Unpack and repack under `fakeroot` with
  a saved state file (`custom-rootfs/.fakeroot`), or files end up owned by
  your user and `/dev` nodes go missing.
- `/etc/checksum.md5` lists md5 sums of ~9250 rootfs files, including
  `firmware1.pub`. `md5Check` in `/etc/init.d/rcS` runs `md5sum -c` and drops
  to a console shell on a mismatch, but **only in the factory "filesystem test"
  start mode** (mode 3), not in a normal phone boot (it's also skipped if the
  U-Boot env has `skipmd5=yes`). A normal boot doesn't check it. The build
  script still keeps it consistent and refuses to build on a mismatch, so
  images stay valid for that check too.

## Contents of a stock image

The payload is the **complete** root filesystem, including:

| Path | Purpose |
|---|---|
| `boot/uImage` | Kernel (Linux 2.6.27.47, ARM, legacy uImage) |
| `boot/u-boot.bin` | Bootloader |
| `update/systemUpdate` | Empty flag: "this is a system (rootfs) update" |
| `update/preSystemUpdate.sh`, `postSystemUpdate.sh`, `updateHelper.sh` | Hooks run around the update |
| `update/boot1_update.bin` | boot1 partition image (only reflashed if its ECC is wrong) |
| `clean.rootfs` + `etc/rootfs_files.lst` | Flag and allow-list for removing stale files in `bin lib sbin usr` |
| `snom/` | The phone application, web UI and default config |

## How the phone installs an image (`/etc/init.d/rcS`)

1. `verifySoftwareUpdateFile`: signature + passphrase recovery with `/firmware1.pub`.
2. `doSoftwareUpdate` first extracts only `update/`:
   - `update/systemUpdate` present → **system update**: run
     `preSystemUpdate.sh`, extract the whole tarball **over `/`** (`tar -xzmf - -C /`;
     nothing is deleted). Newer phones do this from the rescue filesystem
     (`mtdblock4`, "advanced update").
   - flag missing → **application update**: the tarball goes into `/snom_new`,
     which then replaces `/snom`. A full rootfs image without the flag
     therefore wrecks `/snom`.
3. `doSystemUpdatePart2`: if `/boot/uImage` / `/boot/u-boot.bin` differ from
   flash (`/dev/mtd6` / `/dev/mtd1`), erase and flash them. Then run
   `postSystemUpdate.sh`.
4. Next boot, `setUpFileSystems` runs `rm -rf ... /update /boot/* /update.bin`,
   and `cleanUpRootfs` (if `/clean.rootfs` exists) deletes every file in
   `bin lib sbin usr` that isn't in `etc/rootfs_files.lst`, then removes the flag.

So a **running** rootfs is the image contents minus `update/`, `boot/*` and
`clean.rootfs`, plus runtime state (settings in `snom/snomconfig`, `/dev`
nodes from `mdev -s`, `etc/random-seed`). `tools/prepare-pulled-rootfs.sh`
puts that right.

> When adding binaries to `bin lib sbin usr`, also add them to
> `etc/rootfs_files.lst`. Otherwise a `clean.rootfs` pass will delete them.
