# Roadmap and workflow

## Workflow goal: stock + overlay

Today the whole modified rootfs (`custom-rootfs/`) lives only on disk, and it
has been lost once already. The plan is to make every image reproducible from
two inputs:

1. a stock snom image (`original_firmware/`, downloadable, not committed), and
2. an `overlay/` directory **in git** with our added/changed files, plus a
   small manifest for modes, owners and deletions.

Then `build = unpack stock → apply overlay → sign`. The private key is the only
secret that has to be stored outside git.

Steps:

- [ ] Recover the current changes with `rootfs-diff.sh` ([recover-from-device.md](recover-from-device.md))
- [ ] Move them into `overlay/` and add `tools/apply-overlay.sh`
- [ ] Let `build-custom-firmware.sh` take a stock image + overlay directly
- [ ] Check that a clean rebuild matches the rootfs pulled from the phone

## Features

| Feature | Status |
|---|---|
| Root SSH on every boot | done (files need recovering into the overlay) |
| Custom firmware signing key | done (rekeying documented) |
| _ideas, e.g. extra tools (busybox applets, tcpdump), custom web UI pages, logging to syslog server, removing phone-home/provisioning_ | open |

For each feature, record here which files it touches and how it was tested on the device.
