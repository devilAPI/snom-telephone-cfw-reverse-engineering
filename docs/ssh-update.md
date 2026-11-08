# OpenSSH, OpenSSL and htop on the D375

| | Stock | CFW |
|---|---|---|
| OpenSSH | 8.1p1 | 10.2p1 |
| OpenSSL | 1.1.1g | 1.1.1w |
| htop | None | 3.3.0 |

```sh
tools/build/build-ssh.sh       # output in out/ssh/
tools/build/build-htop.sh      # output in out/htop
tools/build/install-ssh.sh     # copies both into rootfs/d375
tools/fw/build-custom-firmware.sh
```

## OpenSSL stays on 1.1.1

`lcsD375` and other closed binaries link `libssl.so.1.1`, so OpenSSL 3 cannot
replace it. 1.1.1w is the last 1.1.1 public release, and it is itself out of
upstream support. It fixes the known issues in 1.1.1g, but it will not get more.

All exported symbols match stock except `BIO_f_zlib`, which only the old `openssl`
command used, and that is replaced too.

## Toolchain

The binaries are dynamic so the image stays small. They are built on Debian
stretch because it is the newest toolchain that targets the phone's glibc 2.19;
`build-ssh.sh` fails if a binary needs a newer symbol. Sources are downloaded on
the host with certificate checks, and OpenSSL's checksum is verified.

## Changes in behaviour

- DSA host keys are gone. An ed25519 key is generated on first boot by `boot.sh`.
- `Subsystem sftp` is set: current `scp` uses SFTP, which stock had no entry for.
- Clients may warn that the host key changed, if they knew it by its DSA key.

## Tested in the D375 VM

- `sshd -t`, login with a current OpenSSH client and default options, `scp`.
- TLS 1.3 from the phone's web server through the new library.
- The `rcS` update sequence on a test image: signature check, passphrase recovery,
  decryption. A tampered image is rejected.

Not tested on a real phone. The update path matters most, so if you flash this,
keep SSH open and test one more update afterwards.

## Build metadata

`rootfs/d375/.fakeroot` is no longer used. It stored owners and device nodes by
inode, so it stopped working once the files were moved. A build then lost all 183
device nodes and every owner, and the image panicked at boot with
`/dev/console is missing`.

`rootfs/d375.manifest` stores the same data by path, and was generated from the
last good image. `tools/fw/rootfs-tar.py` applies it and refuses to produce an image
without `dev/console`. New files get root:root and their mode on disk.

`tools/fw/update-checksums.py` refreshes `etc/checksum.md5` after files change.

## Image size

The update lands in `/tmp`, so the image must fit there. `rcS` now sizes `/tmp` at
64 MB instead of 40 MB. That applies after a build containing it is installed, so
the next image must still fit in 40 MB.

| Step | Image size |
|---|---|
| Before | 38.10 MB |
| Unused files left out (`rootfs/d375.exclude`), identical images hard-linked | 35.65 MB |
| `FINAL=1 tools/fw/build-custom-firmware.sh` (zopfli, about 5 minutes) | 34.11 MB |

- Hard links apply only under `snom/bmp/`, because writing to a linked config file
  would change its twins. The phone's `tar` was tested on them, including unpacking
  over an existing install.
- Do not run PNGs through zopflipng. It saves 0.67 MB raw but makes the image
  0.39 MB larger: gzip over a well-compressed PNG gains less than over the original.
- `boot/uImage` (1.9 MB) and the CJK font (2.3 MB) are the largest remaining items
  that could go, at the cost of a kernel update path and Chinese display.
