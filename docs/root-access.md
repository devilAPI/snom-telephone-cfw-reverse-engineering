# Getting and keeping root access

## D3xx / D7xx (D375, D385, D785, …)

### 1. First root shell: OpenVPN configuration files

This follows [Remote root shell on a snom D785 using OpenVPN configuration files](https://www.encrypted.at/remote-root-shell-on-a-snom-d785-voip-phone-using-openvpn-configuration-files/)
(encrypted.at). It also works on the D375 and D385.

In short: the phone's VPN feature takes an uploaded OpenVPN configuration
bundle, and OpenVPN runs as root. A config with script hooks (`up` and
similar, plus `script-security`) therefore runs commands as root on the phone.
The hook is used to start sshd. The VPN server config lives in `vpn-server/`
(gitignored: it holds keys and config).

Steps:
1. Generate VPN PKI: `./tools/setup-ovpn.sh`
2. Start the OpenVPN server: `cd vpn-server && sudo openvpn --config server.conf`
3. Serve the client tarball: `cd vpn-server && python3 -m http.server 8080`
4. On the phone web UI: **Advanced → VPN → OpenVPN** → set provisioning URL
   to `http://<your-ip>:8080/vpnclient.tar`
5. The phone connects to the VPN and the `up` hook starts sshd
6. SSH in: `ssh root@<phone-vpn-ip>` (empty password by default)

This shell only lasts until the next reboot or VPN reconnect.

### 2. Persistent root: custom firmware with SSH on boot

With root, install a custom `/firmware1.pub` ([signing-keys.md](signing-keys.md))
and flash an image whose rootfs starts sshd at boot.

The D375 custom firmware modifies:
- `/etc/shadow` — root password hash (default: `snom375`)
- `/etc/ssh/sshd_config` — `PermitEmptyPasswords no`
- `/etc/init.d/rcS` — adds `mkdir -p /dev/pts && mount devpts /dev/pts -t devpts && /usr/sbin/sshd`
  after the phone application startup
- `/etc/ssh/ssh_host_rsa_key` — pre-generated host key

Build and flash:
```sh
./tools/fw-pull-from-device.sh <phone-ip> --raw --extract
./tools/prepare-pulled-rootfs.sh decrypted/snomD375-10.1.64.17-SIP-r/rootfs
# edit custom-rootfs/ as needed
./tools/build-custom-firmware.sh
# install custom key on phone, then flash via web UI
```

---

## D8xx (D810, D812, D815, D815W, …)

### 1. First root shell: OpenVPN + development mode

The D8xx line uses the same OpenVPN method for first root access. The VPN
client tarball (`vpn-server/vpnclient.tar`) works the same way — the `up`
hook starts sshd.

The D815W additionally ships with `development=yes` in U-Boot env, which
already starts sshd on boot via `/etc/init.d/rcS` → `getStartMode()`. This
means SSH may already be available without the VPN step (with empty root
password). Check with: `ssh root@<phone-ip>`.

### 2. Persistent root: overlay filesystem (no reflash needed)

The D8xx uses a **read-only UBIFS rootfs** with a **writable unionfs overlay**
backed by the `ubi0:overlay` UBI volume. `/etc` and `/snom` are overlaid:

```
unionfs on /etc type unionfs (rw, dirs=/overlay/etc=rw:/etc=ro)
unionfs on /snom type unionfs (rw, dirs=/overlay/snom=rw:/snom=ro)
```

This means persistent changes to `/etc` survive reboots without building a
custom firmware image. Changes are written to `/overlay/etc/` on the writable
overlay volume.

#### What we changed (D815W, firmware 10.1.226.16)

**Set root password** (`snom815`):
```sh
sed -i 's|^root:[^:]*:|root:'"$(openssl passwd -5 snom815)"':|' /etc/shadow
```

**Disable empty password login**:
```sh
sed -i 's/PermitEmptyPasswords yes/PermitEmptyPasswords no/' /etc/ssh/sshd_config
```

**Unconditional sshd startup** (regardless of `development` U-Boot variable):

The stock `rcS` only starts sshd inside a `if [ "$development" = "development=yes" ]`
block in `getStartMode()`. We patched the `startUp()` function's D815 case
(which runs unconditionally after `startUpDaemons`) to always start sshd:

```sh
sed -i '/\"snomD717\".*\"snomD815\".*\"VTechET635\")/,/;;/ {
    /\/css\/cssload\.sh/a\
        # CFW: always start sshd\
        if [ ! -e "/etc/ssh/ssh_host_rsa_key" ]; then\
            /usr/bin/ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key -N ""\
        fi\
        /usr/sbin/sshd
}' /etc/init.d/rcS
```

This adds sshd startup right after the audio firmware load in the D815 block
of `startUp()`, which runs after `setUpFileSystems`, `cleanUpRootfs`,
`setUpNetwork`, `loadKernelModules`, and `startUpDaemons` — and after devpts
is already mounted.

#### Verifying the overlay changes

```sh
ls -la /overlay/etc/          # shows shadow, ssh/, init.d/ modified
grep PermitEmpty /etc/ssh/sshd_config   # should say "no"
grep "CFW: always start sshd" /etc/init.d/rcS  # should match
```

#### Why not reflash?

We attempted the SWU reflash approach (`swupdate -i` with custom-signed
firmware) but hit two issues:

1. **swupdate silent failure**: when run from CLI with `-i /tmp/firmware.swu`,
   swupdate exits with code 1 and produces zero output (not even to its log
   file). Likely caused by insufficient free tmpfs (90MB SWU in 100MB /tmp).
2. **No `ubiupdatevol`**: the phone lacks mtd-utils, so direct UBI volume
   writes are not possible without cross-compiling tools.
3. **Read-only rootfs**: `/firmware1.pub` and `/firmware1.aes` live on the
   read-only UBIFS root and cannot be replaced for the stock swupdate daemon
   to accept custom-signed images.

The overlay approach is simpler and sufficient for SSH persistence. A full
custom firmware flash would be needed for changes outside `/etc` and `/snom`
(e.g., adding binaries to `/usr/bin`).

### 3. Firmware key dump (for future custom firmware builds)

Three key files were dumped from the D815W:

| File | Location on device | Purpose |
|------|-------------------|---------|
| `/firmware1.pub` | RSA-2048 public key | SWUpdate signature verification (`swupdate -k`) |
| `/firmware1.aes` | AES-256 key + IV | Rootfs decryption (`swupdate -K`) |
| `/firmwareUXM.pub` | RSA-1024 public key | Legacy/UXM compatibility |

These are saved in `keys/snomD815-*`. The AES key format is:
`<64-char hex key> <32-char hex IV>` on a single line.

Decrypt a stock D815 firmware:
```sh
./tools/swu-unpack.sh original_firmware/snomD815-10.1.226.16-SIP-r.swu keys/snomD815-firmware1.aes decrypted/D815-10.1.226.16
```

## SSH client notes

- The D8xx phones run OpenSSH (not dropbear), so modern key algorithms work.
- The D3xx/D7xx may use older dropbear builds that only offer `ssh-rsa`:
  `ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa root@<ip>`
- Don't count on `scp`/`sftp` being on the D3xx phone. The tools stream files with
  `ssh host 'cat > file' < local` and `ssh host cat file > local`.
- The D815W has both `curl` and busybox `wget` available.
