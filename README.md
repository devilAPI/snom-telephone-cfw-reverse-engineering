# snom firmware tools and alpha custom firmware for D375

Tools and notes for building custom firmware for **snom v10 desk phones**.
Currently covers:

| Model | Line | Firmware format | Key type | Status |
|-------|------|-----------------|----------|--------|
| D375 / D385 | D3xx | `.bin` (RSA-1024 + AES-128-CBC) | `firmware1.pub` (RSA-1024) | CFW working |
| D815W | D8xx | `.swu` (SWUpdate, AES-256-CBC UBIFS) | `firmware1.pub` (RSA-2048) + `firmware1.aes` | Decryption working |
| D785 | D7xx | `.bin` (RSA-1024 + AES-128-CBC) | `firmware1.pub` (RSA-1024) | Keys dumped |

> Flashing modified firmware can brick the phone and voids support. Take a full
> backup ([docs/recover-from-device.md](docs/recover-from-device.md)) before
> flashing anything.

# CFW Features (D375)
### Alpha: not production ready, not hardened. Use on a trusted LAN only.

The phone app keeps working: calls, the stock web UI and provisioning are
untouched. Everything below is added on top.

**Access and administration**
- Persistent root SSH (default password `snom375`)
- CFW web panel on port 8080, login `root` + the SSH password ([cfw-login](docs/cfw-login.md), [cfw-settings](docs/cfw-settings.md))
- Recovery buttons: reset the root password, restore the default `sshd_config`
- System info page: uptime, CPU, memory, flash, processes, logs ([sysinfo](docs/sysinfo.md))
- Screenshot button, plus a live remote screen and keypad in the browser ([remote](docs/remote.md))
- *Settings → CFW Tools* menu on the phone itself

**Games** (start them from the panel or from *Settings → Games* on the phone)
- DOOM with sound, Freedoom presets or your own WAD ([doom](docs/doom.md))
- NES (InfoNES) with sound ([nes](docs/nes.md))
- Game Boy / Game Boy Color (Gambatte) ([gb](docs/gb.md))
- Game Boy Advance (gpSP, ARM dynarec) ([gba](docs/gba.md))
- ROMs and WADs load from a URL, bare or inside a `.zip` ([zip](docs/zip.md))
- Saves persist on flash and survive reboots ([saves](docs/saves.md))
- Key maps you can edit per game; volume keys work in game ([keymap](docs/keymap.md))
- Quitting (red hangup key) returns to the phone in about 30 s, no reboot ([quit-without-reboot](docs/quit-without-reboot.md))

**Phone features**
- Intercom / baby monitor: streams the microphone to a browser (works in Safari) or a PC while the phone stays usable. You pick the mic: speakerphone, handset, headset jack or both ([intercom](docs/intercom.md))
- Custom ringtones: upload, preview and assign per line ([ringtones](docs/ringtones.md))
- Scripts menu: run your own shell scripts from the phone, such as wake-on-LAN ([scripts](docs/scripts.md))
- Custom boot splash: any image, resized in the browser, plus theme icons ([theming](docs/theming.md))

## How it works

### D3xx / D7xx (.bin format)

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

### D8xx (.swu format)

The D8xx line uses SWUpdate with AES-256-CBC encrypted UBIFS images. The
decryption key+IV are stored at `/firmware1.aes` on the device. Signature
verification uses RSA-2048 (`/firmware1.pub`). See
[docs/firmware-format-swu.md](docs/firmware-format-swu.md).

```
 stock .swu ──swu-unpack.sh──▶ rootfs (UBIFS)
```

## Repository layout

| Path | Tracked | What |
|---|---|---|
| `tools/fw-unpack.sh` | yes | Verify, decrypt and extract a D3xx/D7xx `.bin` image |
| `tools/swu-unpack.sh` | yes | Decrypt and extract a D8xx `.swu` image |
| `tools/build-custom-firmware.sh` | yes | Pack, encrypt and sign `custom-rootfs/` into a `.bin` (D3xx) |
| `tools/fw-pull-from-device.sh` | yes | Back up a running phone over SSH (rootfs, key, raw flash) |
| `tools/prepare-pulled-rootfs.sh` | yes | Make a pulled rootfs buildable again |
| `tools/rootfs-diff.sh` | yes | Show what a custom rootfs changes compared with stock |
| `tools/snom-webpass.sh` | yes | Change the web UI password via SSH (works after Webex provisioning) |
| `tools/setup-ovpn.sh` | yes | Generate OpenVPN PKI + client tarball for initial root |
| `tools/build-*.sh` | yes | Cross-build the phone binaries (Doom, NES, GB/GBA, intercom, nano, ...) with docker + musl |
| `doom-src/`, `nes-src/`, `retro-src/`, `intercom-src/`, `remote-src/`, `snd/` | yes | Ports, the shared audio/keymap layer and helpers built by the scripts above |
| `keys/` | yes | **Public** firmware keys and AES key files (see [keys/README.md](keys/README.md)) |
| `docs/` | yes | Documentation (start here) |
| `original_firmware/` | no | Stock firmware images from snom |
| `decrypted/` | no | Stock rootfs unpacked by the unpack tools |
| `custom-rootfs/` | no | The rootfs that becomes the custom image (D375) |
| `custom-key/` | no | **Private** signing key: back it up outside git |
| `custom-firmware/` | no | Built images |
| `backups/` | no | Dumps pulled from phones |
| `vpn-server/` | no | OpenVPN server for initial root |

## Documentation

1. [docs/root-access.md](docs/root-access.md): getting the first root shell (OpenVPN method) and keeping it
2. [docs/firmware-format.md](docs/firmware-format.md): `.bin` image layout and crypto (D3xx/D7xx)
3. [docs/firmware-format-swu.md](docs/firmware-format-swu.md): `.swu` image layout and crypto (D8xx)
4. [docs/signing-keys.md](docs/signing-keys.md): trust chain, rekeying, going back to stock
5. [docs/building.md](docs/building.md): building and flashing a custom image
6. [docs/recover-from-device.md](docs/recover-from-device.md): rebuilding this project from a phone that already runs custom firmware
7. [docs/device-notes.md](docs/device-notes.md): hardware/partition/boot facts
8. [docs/cfw-settings.md](docs/cfw-settings.md): the CFW Settings web panel (port 8080) and how it's wired in
9. [docs/building-nano.md](docs/building-nano.md): cross-building a static musl `nano` for the phone
10. [docs/doom.md](docs/doom.md): running DOOM on the phone screen (Boot Doom button)
11. [docs/nes.md](docs/nes.md): running a NES emulator on the phone screen (Boot NES button)
12. [docs/roadmap.md](docs/roadmap.md): planned features and project workflow
13. [docs/sound.md](docs/sound.md): audio architecture and game sound
14. [docs/cfw-dev.md](docs/cfw-dev.md): how panel cards and phone menus are assembled (start here to add a feature)
15. [docs/cfw-login.md](docs/cfw-login.md): panel login with the SSH password
16. [docs/gb.md](docs/gb.md) and [docs/gba.md](docs/gba.md): Game Boy / Color and GBA emulators
17. [docs/zip.md](docs/zip.md), [docs/saves.md](docs/saves.md), [docs/keymap.md](docs/keymap.md), [docs/quit-without-reboot.md](docs/quit-without-reboot.md): shared game infrastructure
18. [docs/intercom.md](docs/intercom.md): microphone streaming and mic selection
19. [docs/ringtones.md](docs/ringtones.md), [docs/scripts.md](docs/scripts.md), [docs/theming.md](docs/theming.md): ringtones, scripts menu, splash and icons
20. [docs/remote.md](docs/remote.md), [docs/sysinfo.md](docs/sysinfo.md): remote screen/keypad and system info

## Quick start

### D3xx (phone already runs custom firmware with SSH)

```sh
./tools/fw-pull-from-device.sh <phone-ip> --raw --extract   # backup + custom-rootfs/
./tools/prepare-pulled-rootfs.sh decrypted/snomD375-10.1.64.17-SIP-r/rootfs
./tools/build-custom-firmware.sh                            # new key, new image
```

### D8xx (decrypt stock firmware with keys from device)

```sh
ssh root@<phone-ip> 'cat /firmware1.pub' > keys/snomD815-firmware1.pub
ssh root@<phone-ip> 'cat /firmware1.aes' > keys/snomD815-firmware1.aes
./tools/swu-unpack.sh original_firmware/snomD815-10.1.226.16-SIP-r.swu keys/snomD815-firmware1.aes decrypted/D815-10.1.226.16
```
