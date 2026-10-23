# Getting and keeping root access

## 1. First root shell: OpenVPN configuration files

This follows [Remote root shell on a snom D785 using OpenVPN configuration files](https://www.encrypted.at/remote-root-shell-on-a-snom-d785-voip-phone-using-openvpn-configuration-files/)
(encrypted.at). It also works on the D375.

In short: the phone's VPN feature takes an uploaded OpenVPN configuration
bundle, and OpenVPN runs as root. A config with script hooks (`up` and
similar, plus `script-security`) therefore runs commands as root on the phone.
The hook is used to start a shell or SSH service. The VPN server this needs
lives in `vpn-server/` (gitignored: it holds keys and config).

See the write-up for the exact bundle format and steps. Record any
D375-specific differences here:

- _TODO: firmware version used, menu path for VPN upload, any differences from the D785._

This shell only lasts until the next reboot or VPN reconnect.

## 2. Persistent root: custom firmware with SSH on boot

With root, install a custom `/firmware1.pub` ([signing-keys.md](signing-keys.md))
and flash an image whose rootfs starts an SSH server at boot. The current
custom image does this.

Exactly how SSH is started (binary, init script, credentials) was set up in an
earlier session that wasn't committed. Recover it with:

```sh
./tools/rootfs-diff.sh decrypted custom-rootfs
```

and record the result here:

- _TODO: SSH server binary and path (dropbear? where from?)_
- _TODO: init hook that starts it (file, runlevel)_
- _TODO: authentication (root password / authorized_keys location)_
- _TODO: host keys: generated on first boot or baked into the image?_

Once known, move these files into the overlay (see [roadmap.md](roadmap.md))
so they're tracked in git.

## SSH client notes

- Older dropbear builds only offer `ssh-rsa`, which modern OpenSSH turns off by default:
  `ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa root@<ip>`
  (the tools take this through `SSH_OPTS="..."`).
- Don't count on `scp`/`sftp` being on the phone. The tools stream files with
  `ssh host 'cat > file' < local` and `ssh host cat file > local`.
