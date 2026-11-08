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

The phone runs the newer D815 phone app (10.1.226.16) on the D375's own kernel,
with your settings, calls and sound working. Everything below is added on top. The
original app stays in the image. See [backport-guide](docs/backport-guide.md).

**Phone app**
- D815 phone app (10.1.226.16) in a chroot on the D375 kernel: SIP, calls, handset, speakerphone, backlight, themes and native side button panels work ([backport-guide](docs/backport-guide.md))
- Keys 11 and 12 work, injected by a shim (they have no LEDs or side panel labels)

**Access and administration**
- Persistent root SSH (default password `snom375`), with OpenSSH 10.2p1 and OpenSSL 1.1.1w in place of the stock 8.1p1 / 1.1.1g ([ssh-update](docs/ssh-update.md))
- Extra tools on the phone: `htop`, `nano`, `curl` ([building-nano](docs/building-nano.md))
- CFW web panel on port 8080 with tabs (System, Games, Screen, Phone, Logs), login `root` + the SSH password ([cfw-login](docs/cfw-login.md), [cfw-settings](docs/cfw-settings.md))
- Logs tab: the system log in the browser
- Settings backup (download `snomconfig` as a tar) and a reboot button
- Recovery buttons: reset the root password, restore the default `sshd_config`
- System info page: uptime, CPU, memory, flash, processes, logs ([sysinfo](docs/sysinfo.md))
- Screenshot button, plus a live remote screen and keypad in the browser ([remote](docs/remote.md))
- *Settings → CFW Tools* menu on the phone itself, with a CFW info screen

**Games** (start them from the panel or from *Settings → Games* on the phone)
- DOOM with sound, Freedoom presets or your own WAD ([doom](docs/doom.md))
- NES (InfoNES) with sound ([nes](docs/nes.md))
- Game Boy / Game Boy Color (Gambatte) ([gb](docs/gb.md))
- Game Boy Advance (gpSP, ARM dynarec) ([gba](docs/gba.md))
- ROMs and WADs load from a URL, bare or inside a `.zip` ([zip](docs/zip.md))
- Saves persist on flash and survive reboots ([saves](docs/saves.md))
- Key maps you can edit per game; volume keys work in game ([keymap](docs/keymap.md))
- Games on keys: put a game on a function key; pressing it downloads and starts the game ([keymap](docs/keymap.md#games-on-keys))
- Quitting (red hangup key) returns to the phone in about 30 s, no reboot ([quit-without-reboot](docs/quit-without-reboot.md))

**Phone features**
- Intercom / baby monitor: streams the microphone to a browser (works in Safari) or a PC while the phone stays usable. You pick the mic: speakerphone, handset, headset jack or both ([intercom](docs/intercom.md))
- Network speaker / reverse intercom: play a file from the panel, or add a "snom D375" sound output to a Linux PC (PulseAudio or PipeWire) and hear the PC on the phone's loudspeaker. Works at the same time as the intercom. You choose the output: loudspeaker, or the handset earpiece (experimental) ([speaker](docs/speaker.md))
- Navidrome / Subsonic player: browse artists, albums, playlists and search on the phone, play on the loudspeaker; MP3 decoded on the phone with libmad ([navidrome](docs/navidrome.md))
- Custom ringtones: upload, preview and assign per line ([ringtones](docs/ringtones.md))
- Scripts menu: run your own shell scripts from the phone, such as wake-on-LAN ([scripts](docs/scripts.md))
- Scripts on keys: assign a script to a function key from the panel; survives reboots ([backport-guide](docs/backport-guide.md#running-a-script-from-a-key))
- Custom boot splash: any image, resized in the browser, shown at boot and in the phone app, plus theme icons ([theming](docs/theming.md))
- Idle-screen widgets: panel card exists but does not work with the current app ([idle-screen](docs/idle-screen.md))

**Development**
- QEMU machines for the D375 and D815 that boot the real firmware images, registered in virt-manager ([qemu](docs/qemu.md))
- One CFW tree that builds for several models (started) ([multi-model](docs/multi-model.md))
- Signed D375 dev images built by GitHub Actions ([ci-releases](docs/ci-releases.md))

## How it works

### D3xx / D7xx (.bin format)

The phone accepts a firmware image if it is signed with the private half of
the RSA key it stores at `/firmware1.pub`. Once you have root on the phone, you
can swap that file for your own public key. From then on the phone accepts
images you sign. See [docs/firmware-format.md](docs/firmware-format.md) and
[docs/signing-keys.md](docs/signing-keys.md).

```
 stock .bin ──fw-unpack.sh──▶ rootfs ──(your changes)──▶ rootfs/d375 ──build-custom-firmware.sh──▶ custom .bin
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

Everything is tracked in git, including the signing keys (they are public on
purpose, so anyone can build images for a phone running this CFW).

```
src/                 our code
  cfw-d815/          the D815's own panel files; the rest is shared from rootfs/d375/snom/cfw
  games/             doom/, nes/, retro/ (the GB/GBC and GBA frontend)
  audio/             snd/ (shared halaudio + keymap layer), intercom/, navidrome/
  remote/            screen capture and key injection
  native/            small C helpers: bindmount, fb24shim (+ keymap.h), rtcap
  host/              linux-tel-wrapper (tel: links on a Linux PC)
tools/
  fw/                unpack, build, sign and diff firmware images (start: build-custom-firmware.sh)
  build/             docker + musl cross-builds of the phone binaries, output in out/
  qemu/              QEMU machines, NAND images, virt-manager VMs
  device/            scripts that talk to a phone: speaker, intercom, D815 app trials, web password, VPN
  backport/          staging the D815 phone app for the D375
  media/             splash, icons, theme images
  analysis/          one-off reverse-engineering helpers
tests/               on-phone feature tests (tests/lib.sh)
out/                 cross-built binaries
rootfs/
  d375/              the D375 CFW rootfs; its snom/cfw/ holds the D375 CFW code
  d375.manifest      owners, modes and device nodes for d375/
  d375.exclude       files left out of the D375 image
  d815/              the D815 CFW rootfs
  stock/             stock rootfs trees unpacked by the unpack tools
firmware/
  stock/             stock images from snom
  custom/            built images; custom/previous/ keeps older builds
keys/
  stock/             snom's public keys and the D815 AES key (see keys/README.md)
  custom-d375/       our D375 signing key (CI gets it from a repository secret)
  custom-d815/       our D815 signing and AES keys
emu/                 QEMU board models (board/), D815 overlay, VM disks
backups/             dumps pulled from phones
vpn/                 OpenVPN server and phone tarball for the first root
third_party/gpl/     snom's GPL source tarball
docs/                documentation (start here)
.github/workflows/   CI: signed D375 dev images as GitHub pre-releases
```

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
18. [docs/intercom.md](docs/intercom.md): microphone streaming and mic selection; [docs/speaker.md](docs/speaker.md): the reverse direction, sound to the loudspeaker; [docs/navidrome.md](docs/navidrome.md): the music player built on it
19. [docs/ringtones.md](docs/ringtones.md), [docs/scripts.md](docs/scripts.md), [docs/theming.md](docs/theming.md): ringtones, scripts menu, splash and icons
20. [docs/remote.md](docs/remote.md), [docs/sysinfo.md](docs/sysinfo.md): remote screen/keypad and system info
21. [docs/ci-releases.md](docs/ci-releases.md): dev images built and released by GitHub Actions
22. [docs/backport-guide.md](docs/backport-guide.md): the D815 phone app on the D375 ([backport.md](docs/backport.md) has the history)
23. [docs/ssh-update.md](docs/ssh-update.md): newer OpenSSH, OpenSSL and htop
24. [docs/qemu.md](docs/qemu.md), [docs/multi-model.md](docs/multi-model.md): the emulator and the multi-model codebase
25. [docs/idle-screen.md](docs/idle-screen.md): idle-screen widget findings

## Quick start

### D3xx (phone already runs custom firmware with SSH)

```sh
./tools/fw/fw-pull-from-device.sh <phone-ip> --raw --extract   # backup + rootfs/d375/
./tools/fw/prepare-pulled-rootfs.sh rootfs/stock/snomD375-10.1.64.17-SIP-r/rootfs
./tools/fw/build-custom-firmware.sh                            # new key, new image
```

### D8xx (decrypt stock firmware with keys from device)

```sh
ssh root@<phone-ip> 'cat /firmware1.pub' > keys/stock/snomD815-firmware1.pub
ssh root@<phone-ip> 'cat /firmware1.aes' > keys/stock/snomD815-firmware1.aes
./tools/fw/swu-unpack.sh firmware/stock/snomD815-10.1.226.16-SIP-r.swu keys/stock/snomD815-firmware1.aes rootfs/stock/D815-10.1.226.16
```
