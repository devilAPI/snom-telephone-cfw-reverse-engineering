# snom D375 custom firmware

Tools and notes for building custom firmware for the **snom D375** desk phone
(firmware v10, D3xx line). The aim is to add features to the stock firmware,
starting with a root SSH shell that comes up on every boot.

> Flashing modified firmware can brick the phone and voids support. Take a full
> backup ([docs/recover-from-device.md](docs/recover-from-device.md)) before
> flashing anything.

## How it works

The phone accepts a firmware image if it is signed with the private half of
the RSA key it stores at `/firmware1.pub`. Once you have root on the phone, you
can swap that file for your own public key. From then on the phone accepts
images you sign. See [docs/firmware-format.md](docs/firmware-format.md) and
[docs/signing-keys.md](docs/signing-keys.md).

```
 stock .bin ──fw-unpack.sh──▶ rootfs ──(your changes)──▶ custom-rootfs ──build-custom-firmware.sh──▶ custom .bin
                                                              ▲
 running phone ───────────fw-pull-from-device.sh──────────────┘   (recovery path)
```

## Repository layout

| Path | Tracked | What |
|---|---|---|
| `tools/fw-unpack.sh` | yes | Verify, decrypt and extract a `.bin` image |
| `tools/build-custom-firmware.sh` | yes | Pack, encrypt and sign `custom-rootfs/` into a `.bin` |
| `tools/fw-pull-from-device.sh` | yes | Back up a running phone over SSH (rootfs, key, raw flash) |
| `tools/prepare-pulled-rootfs.sh` | yes | Make a pulled rootfs buildable again (restore `update/`, `boot/`, stock config) |
| `tools/rootfs-diff.sh` | yes | Show what a custom rootfs changes compared with stock |
| `keys/` | yes | **Public** firmware keys (see [keys/README.md](keys/README.md)) |
| `docs/` | yes | Documentation (start here) |
| `original_firmware/` | no | Stock `.bin` images from snom |
| `decrypted/<image>/rootfs` | no | Stock rootfs unpacked by `fw-unpack.sh` |
| `custom-rootfs/` | no | The rootfs that becomes the custom image |
| `custom-key/` | no | **Private** signing key: back it up outside git |
| `custom-firmware/` | no | Built images |
| `backups/` | no | Dumps pulled from phones |
| `gpl_src/`, `vpn-server/` | no | GPL source tarball, OpenVPN server for initial root |

The vendor rootfs and images stay out of git because they are large and
contain proprietary snom binaries. The plan is to track our changes as a small
overlay applied on top of stock (see [docs/roadmap.md](docs/roadmap.md)).

## Documentation

1. [docs/root-access.md](docs/root-access.md): getting the first root shell (OpenVPN method) and keeping it
2. [docs/firmware-format.md](docs/firmware-format.md): image layout and crypto
3. [docs/signing-keys.md](docs/signing-keys.md): trust chain, rekeying, going back to stock
4. [docs/building.md](docs/building.md): building and flashing a custom image
5. [docs/recover-from-device.md](docs/recover-from-device.md): rebuilding this project from a phone that already runs custom firmware
6. [docs/device-notes.md](docs/device-notes.md): hardware/partition/boot facts (fill these in as they are confirmed)
7. [docs/roadmap.md](docs/roadmap.md): planned features and project workflow

## Quick start (phone already runs custom firmware with SSH)

```sh
./tools/fw-pull-from-device.sh <phone-ip> --raw --extract   # backup + custom-rootfs/
./tools/prepare-pulled-rootfs.sh decrypted/snomD375-10.1.64.17-SIP-r/rootfs
./tools/build-custom-firmware.sh                            # new key, new image
```

Then follow the key install steps the build script prints, and flash.
