# Dev images from GitHub Actions

`.github/workflows/dev-image.yml` builds a signed D375 image from the tracked
`rootfs/d375/` with `tools/fw/build-custom-firmware.sh` and publishes it as a
**pre-release** on GitHub.

- **When:** on every push to `main` or `cfw-features` that touches `rootfs/d375/`,
  the build script or the workflow, and by hand (Actions → *D375 dev image* → *Run workflow*).
- **Where:** one rolling pre-release per branch, tag `dev-<branch>` (e.g. `dev-cfw-features`).
  Each run deletes the old one and uploads `snomD375-10.1.64.17-SIP-r.bin` plus a `.sha256`.
- **What it does not do:** rebuild the game/intercom binaries. Those are committed inside
  `rootfs/d375/` (build them locally with `tools/build/build-*.sh`).

## One-time setup: the signing key

The phone only installs an image signed with the key whose public half is in
the image it runs (`/firmware1.pub`, see [signing-keys.md](signing-keys.md)).
CI needs that private key as the repository secret `FIRMWARE_PRIV_PEM`:

    gh secret set FIRMWARE_PRIV_PEM < keys/custom-d375/firmware.priv.pem

(or GitHub → Settings → Secrets and variables → Actions → New repository secret).
The job fails without the secret, and it also fails if the key does not match
`rootfs/d375/firmware1.pub`. Otherwise the build script would write a
different key into the image and lock the phone out of later updates.

Anyone with write access to the repo can read the secret through a workflow.
Treat repo write access as access to the signing key. Pull requests from forks
never get it, and the workflow does not run on PRs.

## Why the CI image matches a local build

Locally the rootfs tarball is packed under `fakeroot -i rootfs/d375/.fakeroot`.
That database is keyed by the inode numbers of *your* checkout, so CI deletes it.
Without it the build script packs with `--owner=0 --group=0`. That is exact for this
tree: every entry is root:root with mode 644/755 (or a symlink), and there are no
device nodes, setuid files or empty directories (dev nodes are made at boot).
Checked 2026-10-31: a clean-clone build gave the same 10356 entries (mode, owner,
size, name) as the local image.

If you ever add a device node, a non-root owner or an unusual mode to the rootfs,
git cannot store it and the CI image will differ. Build that image locally.

## Flashing a dev image

Only on a D375 that already runs this CFW. Back up first ([recover-from-device.md](recover-from-device.md)),
check the sha256, then *Software Update → URL* with the release asset's download link
(or serve it from your PC, see [building.md](building.md)).
