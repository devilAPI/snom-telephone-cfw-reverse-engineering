# Building `nano` for the D375

The phone is **ARMv6 softfloat (no VFP)** running **kernel 2.6.27**. Two things
bite a naive build:

1. A glibc static binary from a current toolchain floors at **kernel 3.2** and
   **segfaults (rc 139)** on 2.6.27.
2. The CPU has no hardware float, so a hardfloat (`gnueabihf`/VFP) binary is the
   wrong ABI.

The fix: build a **fully static binary against musl** with a **softfloat
(`arm-linux-musleabi`)** toolchain. musl supports old kernels, and static
linking sidesteps the phone's ancient libc entirely.

## Build

`tools/build-nano.sh` runs the whole thing in a Debian container (needs
`docker`). Output: `tools/out/nano`, an ARM EABI5 static binary that runs on the
phone (verified: full curses UI, clean exit).

Key choices, if you build it by hand:

- Toolchain: `arm-linux-musleabi-cross` from <https://musl.cc> (softfloat).
- `CFLAGS="-Os -march=armv4t"` — armv4t baseline runs on ARMv6.
- **ncurses**: static, `--enable-widec` (UTF-8), and **compiled-in terminfo
  fallbacks** (`--with-fallbacks=linux,vt100,vt102,xterm,xterm-256color,ansi,screen`)
  because the phone has no terminfo database.
- **nano**: `LDFLAGS="-static"`, `LIBS="-lncursesw"`,
  `--disable-nls --disable-libmagic --disable-speller`.

## Installing into the image

Copy to `custom-rootfs/usr/bin/nano`, record root ownership in the fakeroot db
(`fakeroot -i .fakeroot -s .fakeroot sh -c 'chown 0:0 usr/bin/nano && chmod 755 usr/bin/nano'`),
and **add `usr/bin/nano` to `etc/rootfs_files.lst`** or the first-boot
`cleanUpRootfs` pass deletes it (see [cfw-settings.md](cfw-settings.md)).
