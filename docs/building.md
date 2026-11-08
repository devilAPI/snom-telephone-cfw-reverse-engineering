# Building and flashing a custom image

## Requirements

- `openssl` (1.1 or 3.x), `tar`, `gzip`, `bash`
- `fakeroot` (strongly recommended: keeps ownership and `/dev` nodes)

## Getting a rootfs to build from

Use either:

- **stock**: `./tools/fw/fw-unpack.sh firmware/stock/<image>.bin keys/stock/snomD375-firmware1.pub rootfs/d375`
  (this creates `rootfs/d375/.fakeroot`), then apply your changes, or
- **from a phone**: `./tools/fw/fw-pull-from-device.sh <ip> --extract`, then
  `./tools/fw/prepare-pulled-rootfs.sh <stock-rootfs>` ([recover-from-device.md](recover-from-device.md)).

Edit files inside the fakeroot session so their ownership is recorded:

```sh
fakeroot -i rootfs/d375/.fakeroot -s rootfs/d375/.fakeroot bash
```

## Build

```sh
./tools/fw/build-custom-firmware.sh
```

What it does:

1. Generates `keys/custom-d375/firmware.priv.pem` + `firmware.pub` (RSA-1024) if they're missing
2. **1b.** Writes `firmware.pub` into `rootfs/d375/firmware1.pub` and updates `etc/checksum.md5`
3. **1c.** Refuses to build without `update/systemUpdate`, or if `etc/checksum.md5` doesn't match
4. Tars `rootfs/d375/` in sorted order (under fakeroot when `.fakeroot` exists)
5. Encrypts it with a random passphrase (AES-128-CBC, MD5 KDF)
6. Signs the passphrase into the key block
7. Signs key block + payload (SHA-1)
8. Writes `firmware/custom/snomD375-custom-SIP-r.bin` and decrypts it back as a check

## Flash

1. Make sure the phone's `/firmware1.pub` matches `keys/custom-d375/firmware.pub`
   (the build script prints the install steps, see also [signing-keys.md](signing-keys.md)).
2. Serve the image over HTTP, e.g. `python3 -m http.server -d firmware/custom 8000`.
3. Phone web UI → Software Update → enter `http://<pc-ip>:8000/snomD375-custom-SIP-r.bin`.

If the signature check fails, the phone rejects the image and keeps running
its current firmware. A bad rootfs that does pass the check (broken init,
missing `/dev` nodes, wrong ownership) is the real bricking risk. Keep the raw
backup from `fw-pull-from-device.sh --raw`.

## Pre-flash checklist

- [ ] Raw backup of this phone exists in `backups/`
- [ ] `keys/custom-d375/` is backed up outside the repo
- [ ] Phone `/firmware1.pub` == `keys/custom-d375/firmware.pub`
- [ ] `rootfs-diff.sh` against stock shows only intended changes
- [ ] The SSH-on-boot change is still in the rootfs (so you keep a way back in)
- [ ] New files in `bin lib sbin usr` are listed in `etc/rootfs_files.lst`
- [ ] Changed files have updated entries in `etc/checksum.md5` (the build checks this)
