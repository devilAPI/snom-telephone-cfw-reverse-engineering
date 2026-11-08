# One CFW codebase for several models

Status: started. The panel and startup hook are shared; `rootfs` trees and games
are still per model.

## What exists now

- `src/cfw/panel/`: panel, CGIs and `boot.sh`, shared by both models.
- `src/cfw/models/<model>.conf`: name, default password, feature list.
- `tools/fw/cfw-sync.sh <model> <rootfs>`: installs the above and the one `rcS` hook.
  Both firmware build scripts call it.
- The panel page is generated, so unsupported features are not shown.

Tested on both VMs: login, status, logs, settings backup, screenshot at 24 and 32
bpp. Remote control and reboot work on the D375; see `docs/cfw-settings.md` for
the D815 limits. Next: move `rootfs/d375` to stock + changes (step 1 below).

Yes, this works. Almost all of the CFW is shell, CGI and configuration, which do
not depend on the model. Only a small part touches hardware. The firmware images
themselves stay separate, because each one starts from that model's stock rootfs.

## Measured

D375 is the reference: features are written and proven there, then ported.

The D375 CFW is small. Against stock 10.1.64.17 it is:

- A 5-line `rcS` change, 11 lines in the phone's menu and web nav, 2 in
  `sshd_config`, 1 in `rootfs_files.lst`.
- 15 files in `/snom/cfw` (772 KB, mostly two game binaries).
- `nano`, `openvpn`, 8 replaced icons, the root password and the signing key.

Tests run on 2026-10-31:

| Test | Result |
|---|---|
| D375 patches on stock D375 10.1.64.14 | All apply cleanly |
| D375 patches on stock D815 | All apply, but `rcS` lands in the `snomD375` case, which never runs there |
| CFW panel on the D815 VM, unchanged | Serves pages |
| `screenshot` CGI on the D815 VM | Runs, but assumes 32 bpp; the D815 is 24 bpp |
| `doom` and `infones` binaries on the D815 VM | Both start. Not played: no game data, no keypad model |
| Sound on the D815 | `/dev/halaudio` does not exist |
| D385 images | Cannot be opened: no key in `keys/` matches them |

snom does the same thing: the stock D815 `rcS` is one script covering every model
through `case $PHONE_TYPE`, and still contains the `snomD375` branch.

## What differs

| | D375 | D815 |
|---|---|---|
| CPU | ARMv6 | ARMv5 |
| Kernel | 2.6.27 | 3.4 |
| Rootfs | Writable JFFS2 | Read-only UBIFS, unionfs over `/snom` and `/etc` |
| Image | `.bin`, RSA-1024, AES-128 | `.swu`, RSA-2048, AES-256 |
| Screen | 32 bpp | 24 bpp |
| Audio | halaudio | ALSA and CSS |
| Keys | Codes from `docs/doom.md` | Different keymap (device tree) |

## Rules this leads to

- Do not patch model `case` branches. Add one hook line that runs
  `/snom/cfw/boot.sh`, and keep startup logic there.
- Read hardware facts at run time: bits per pixel, stride, keymap by model.
- Every feature declares which models it supports, so the panel hides what a
  model lacks. An unported feature is then a missing button, not a broken one.
- Replacing the DECT icon is a D375-only trick: the D815 has DECT hardware, so it
  needs another icon.

## Layout

```
src/cfw/
  common/            files for every phone: panel, CGI, sshd setup
  models/d375/       model.conf, overlay files, rcS patch
  models/d815/       model.conf, overlay files, rcS patch
  apps/              C sources: Doom, NES, GBA
  lib/               fb.c, input.c, audio_hal.c, audio_alsa.c
tools/build.sh <model>
```

`model.conf` holds the facts: stock image, architecture, screen format, keymap,
audio backend, default password, packaging step.

`tools/build.sh d815` then does the same steps for every model:

1. Unpack the stock image with modes preserved, in Docker.
2. Copy `common/`, then `models/<model>/`, over it.
3. Apply the `rcS` patch.
4. Build the apps for that architecture.
5. Package and sign with the model's format.
6. Run `tools/qemu/vm-update.sh <model>`.

Step 1 removes the need for `rootfs/d375/` and `rootfs/d815/`. Those trees
hold the whole stock firmware, which is why they are not in git and were lost once.
Only the changes would be tracked, and the rootfs becomes a build product.

## Native code

The static musl binaries built for `armv4t` start on both phones, so one binary
can serve both. A small `lib/` layer covers the differences:

- **Screen**: read the format from `FBIOGET_VSCREENINFO`. This is a run-time
  check, so one binary can cover both models.
- **Input**: load the keymap for the model.
- **Audio**: the only part with a real backend per model. The D815 backend cannot
  be tested in QEMU, because neither model has audio.

## Migration order

1. Move the D815's six changed files and the D375's overlay into `src/cfw/`, and make
   the output match today's images.
2. Move the shared panel into `common/`, with a model check where needed.
3. Add the screen and input layer, and port one app (Doom) to the D815.
4. Do D815 audio last, on real hardware.

The D385 first needs its `firmware1.pub`, which has to be read from a D385 phone.
The D785 could join with its own `models/` folder.
