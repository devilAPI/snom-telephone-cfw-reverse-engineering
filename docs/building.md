# Building and flashing a custom image

## Requirements

- `openssl` (1.1 or 3.x), `tar`, `gzip`, `bash`
- `fakeroot` (strongly recommended: keeps ownership and `/dev` nodes)

## Getting a rootfs to build from

Use either:

- **stock**: `./tools/fw-unpack.sh original_firmware/<image>.bin keys/snomD3xx-firmware1.pub custom-rootfs`
  (this creates `custom-rootfs/.fakeroot`), then apply your changes, or
- **from a phone**: `./tools/fw-pull-from-device.sh <ip> --extract`, then
  `./tools/prepare-pulled-rootfs.sh <stock-rootfs>` ([recover-from-device.md](recover-from-device.md)).

Edit files inside the fakeroot session so their ownership is recorded:

```sh
fakeroot -i custom-rootfs/.fakeroot -s custom-rootfs/.fakeroot bash
```

## Build

```sh
./tools/build-custom-firmware.sh
```

What it does:

1. Generates `custom-key/firmware.priv.pem` + `firmware.pub` (RSA-1024) if they're missing
2. **1b.** Writes `firmware.pub` into `custom-rootfs/firmware1.pub` and updates `etc/checksum.md5`
3. **1c.** Refuses to build without `update/systemUpdate`, or if `etc/checksum.md5` doesn't match
4. Tars `custom-rootfs/` in sorted order (under fakeroot when `.fakeroot` exists)
5. Encrypts it with a random passphrase (AES-128-CBC, MD5 KDF)
6. Signs the passphrase into the key block
7. Signs key block + payload (SHA-1)
8. Writes `custom-firmware/snomD375-custom-SIP-r.bin` and decrypts it back as a check

## Flash

1. Make sure the phone's `/firmware1.pub` matches `custom-key/firmware.pub`
   (the build script prints the install steps, see also [signing-keys.md](signing-keys.md)).
2. Serve the image over HTTP, e.g. `python3 -m http.server -d custom-firmware 8000`.
3. Phone web UI → Software Update → enter `http://<pc-ip>:8000/snomD375-custom-SIP-r.bin`.

If the signature check fails, the phone rejects the image and keeps running
its current firmware. A bad rootfs that does pass the check (broken init,
missing `/dev` nodes, wrong ownership) is the real bricking risk. Keep the raw
backup from `fw-pull-from-device.sh --raw`.

## Pre-flash checklist

- [ ] Raw backup of this phone exists in `backups/`
- [ ] `custom-key/` is backed up outside the repo
- [ ] Phone `/firmware1.pub` == `custom-key/firmware.pub`
- [ ] `rootfs-diff.sh` against stock shows only intended changes
- [ ] The SSH-on-boot change is still in the rootfs (so you keep a way back in)
- [ ] New files in `bin lib sbin usr` are listed in `etc/rootfs_files.lst`
- [ ] Changed files have updated entries in `etc/checksum.md5` (the build checks this)
