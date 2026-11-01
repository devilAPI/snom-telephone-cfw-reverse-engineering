# Running a newer phone app on an older snom phone

The D375 CFW now uses the D815 phone app (`lcsD815`, 10.1.226.16). The app lives on
flash in `/snom/d815` and runs in a chroot on the D375's own kernel. This page is
how that works, how to change it, and how to repeat it for another model.
[backport.md](backport.md) has the history.

## What works on a D375

| | State | How it was checked |
|---|---|---|
| App boots from flash with the phone's settings | Works | Real phone, 0 errors in the log |
| Network start, DHCP, DNS, NTP | Works | Real phone, app's own start |
| SIP registration | Works | Web status says `Registriert` |
| Calls, handset, speakerphone, sound | Works | Test call by hand |
| Most keys | Work | By hand |
| Settings key | Fixed | Command checked on the phone; press the key to confirm |
| Backlight | Fixed | Setting 3 and 15 reach the hardware as 6 and 30 of 32 |
| Icons, background, Contrast theme | Works | 0 `ToImage` errors |
| Side button panels on the idle screen | Gone | Framebuffer capture while registered |
| Games menu | Works | Opens on the phone with its icon |
| Starting a game | Untested | Doom now stops `lcsD815`; run it to confirm |
| CFW panel on port 8080 | Partly tested | Key press helper works; the rest is unchanged |
| A few keys | Open | See below |
| Incoming calls, headset | Untested | |

Keys with no D815 code are logged to `/snom/d815/tmp/unmapped-keys` with their D375
key code. Press the keys that do nothing, then read that file.

The installed `.bin` itself has not been flashed yet. The same files were tested on
the phone with `tools/d815-try-flash.sh`.

## Build and test

```sh
tools/build-custom-firmware.sh      # FINAL=1 for the smallest image
tools/d815-try-flash.sh [phone-ip]  # try it on a phone, without a firmware update
```

`tools/build-custom-firmware.sh` runs `tools/backport/stage.py`, adds the result to
the image, and updates the VM. To change the file selection, delete
`emu/backport/d8.tar` first so that `pack.py` runs again. After changing
`tools/fb24shim.c`, run `tools/build-fb24shim.sh`.

`tools/d815-try-flash.sh` is the fast way to test: it copies the staged files to the
phone and reboots once into them. It takes about 4 minutes, and the phone is
registered about a minute after that. The next reboot runs the installed firmware
again. The copied files stay on flash and take about 26 MB.

### Installing the image

The image is 52 MB. Older CFW builds have a 40 MB `/tmp`, where the update has to
fit, so make room once before installing:

```sh
mount -o remount,size=64M /tmp
```

Then install it as usual. Images from now on set 64 MB themselves.

### Going back to the D375 app

The original app is still in the image:

```sh
touch /snom/cfw-data/use-d375-app && reboot
```

Delete that file to return to the D815 app.

### Settings and login

The app keeps its settings in `/snom/snomconfig/d815`. The first boot copies the
phone's settings there, removes `setting_server`, turns off the side panels, and
sets the web login to `admin` and the model's default password, `snom375` on a D375.
The original settings stay as they are, for the D375 app. To start again, delete
that folder and reboot.

### Testing from RAM

`tools/d815-on-d375.sh` is the older method. It runs the app from a RAM disk and
writes less to flash, but uses 49 MB of RAM and its web login is fixed. Use it only
for a change to the file selection on a phone with little free flash.

## How it fits together

| Part | File | Job |
|---|---|---|
| File selection | `tools/backport/pack.py` | Picks the app and its libraries, writes `d8.tar` |
| Staging | `tools/backport/stage.py` | Lays out `/snom/d815` and the extra icons |
| Boot | `cfw/app/start-d815.sh` | Sets up the chroot and config, starts `lid` |
| Hook | `tools/cfw-sync.sh` | Makes `start.sh` run the boot script |
| Runtime shim | `tools/fb24shim.c` | Loaded with `/etc/ld.so.preload`; adapts the hardware differences |
| Key table | `tools/backport/keymap.py` | Generates `keymap.h` from both `lid` binaries |
| Key helper | `/snom/d815/bin/phone-key` | Presses a key through `command.htm` with the current login |

Nothing in `tmp`, `var`, `run` or `dev` of the chroot reaches the flash: they are
8 MB RAM disks.

The D375's own `media_daemon` runs outside the chroot, and the app reaches it on
`127.0.0.1:1299`. A sleeping stub stands in for the D815's own one. Sound works
this way, despite the `SetupAudioDevice` format difference noted in
[d785-evaluation.md](d785-evaluation.md).

## Every difference, and its fix

Each row cost real time to find. Check all of them on any new port.

| Symptom | Cause | Fix | Where |
|---|---|---|---|
| Wrong colours or broken screen | App draws 24bpp, D375 is 32bpp BGRX | Shadow framebuffer, 20 Hz copier | shim |
| Wrong keys | Each model has its own code-to-key table | Pair codes by key ID | `keymap.py`, shim `read()` |
| Handset reversed: dial tone on the cradle | Hook bit has opposite sense | Invert key 102 in events and `EVIOCGKEY` | shim |
| Settings key does nothing | No D815 equivalent, and `command.htm` needs a login | Run `phone-key SETTINGS` | shim, `stage.py` |
| Backlight setting does nothing | `dvf9a-bl` is absent; the app runs `stat` first, then writes 0 to 64 | Redirect `stat` and `open`; scale to 0 to 32 | shim |
| Web panel keys fail | Same login | Use `phone-key` | `cfw/panel/cgi-bin/key` |
| Games leave the app running | They stop `lcsD375` by name | Stop both names | `doomgeneric_snom.c` |
| Stuck on "Neuen HTTP-Benutzernamen eingeben" | No web credentials set | Add them to the app's config | `start-d815.sh` |
| All icons fail: `Can't get raw image` | Imlib2 loaders use `dlopen` | Add `usr/lib/imlib2/loaders` | `pack.py` |
| `No image found for icon type` | Theme or icon missing from flash | Add D815-only icons; link Contrast to Dark | `stage.py` |
| No host name resolves | `libnss_dns` is opened with `dlopen` | Add `libnss_dns`, `libnss_files` | `pack.py` |
| "SIP abgeschaltet" | `gsw120` switch sysfs is absent | Redirect it to `eth0`'s carrier and stand-in files | shim `redirect()` |
| Identity never registers | "Stack enabled" byte never gets set | Set the byte at runtime | shim `enable_sip_stack()` |
| Provisioning from the wrong URL | `setting_server` serves D375 files | Delete it from the app's config | `start-d815.sh` |
| `LD_PRELOAD` has no effect | `lid` clears the environment | Use `/etc/ld.so.preload` in the chroot | `stage.py` |
| Reboot after about a minute | Softdog needs feeding, and killing `lid` makes `rcS` reboot | Keep `lid` running | Keep in mind |

### The SIP stack byte is a workaround

`enable_sip_stack()` writes to a fixed address, `0x10eac80`, which fits only this
exact `lcsD815` build. Nothing sets that byte on a D375, and the code that normally
does was not found. A rebuilt app needs the address found again:

1. Find the string `Stack is disabled, message being dropped`.
2. Find its address in a literal pool, and the `ldr` that loads it.
3. The function start loads a global pointer, then tests byte 0 of what it points to.

Do not reuse the address on another model or version: it would write to something
else. The cleaner fix, still open, is to find what sets the byte on a real D815.

### Icons

`stage.py` adds the 30 D815-only icons to `/snom/bmp`, and makes
`theme_contrast` a tree of real folders holding symlinks to the Dark icons. The app
does not follow symlinked folders, but symlinked files are fine. The chroot then
needs only one bind mount of `/snom/bmp`.

## Porting to another model

Work through these in order. Steps 2 to 6 need nothing from the phone.

1. **Get the firmware.** `tools/fw-unpack.sh` works only with keys that are already
   in `keys/`. Do not try to recover a signing key. There is no D385 key, so the
   D385 is out of scope.
2. **Compare the CPU.** Run `readelf -A` on the app. The target CPU must run it:
   the D375 is ARMv6, so ARMv5 and ARMv6 apps run on it. An ARMv7 app does not.
3. **Compare the C library and kernel.** `file` shows the minimum kernel, and
   `readelf -V` the glibc symbols. The chroot brings its own glibc, so only the
   kernel floor matters. Older kernels also lack newer system calls.
4. **Compare the screen.** The app needs the target's resolution. The shim converts
   pixel formats, not sizes. Check bits per pixel and channel order on both models.
5. **Compare the keys.** Run `keymap.py` on both `lid` binaries. List the codes with
   no match, then decide what each should do.
6. **List what is loaded at runtime.** `readelf` cannot see `dlopen`. Search the
   rootfs for plugin folders and NSS libraries, and compare them with `d8.tar`.
7. **Check the audio protocol.** `strings` on both `media_daemon` binaries shows the
   `LPCP/` version and verbs. A different `SetupAudioDevice` format means audio
   needs a proxy, or the other model's daemon.
8. **Search the app for hardware paths.** `strings` for `/sys/`, `/dev/` and `/proc/`,
   then check each on the target. These are what the shim has to answer.
9. **Boot it and read the log.** Use `http://<phone>/log.htm`, and set `log_level=9`.
   Fix `FATAL`, then `ALERT`, then go through the table above.

### Which app to use

- **D815 app:** the one in use. See [d785-evaluation.md](d785-evaluation.md) for why
  it stayed the base over the D785.
- **D785:** closest to the D375 in hardware, but it has fewer of the D375's keys and
  its labels sit on a second screen. Its `media_daemon` is worth trying on the D375.

## Debugging

- Screen capture: `cat /dev/fb0` over SSH, 1044480 bytes, BGRA, 480 wide.
- `pkill -f name` from `ssh` also matches the remote shell. Use `kill` with a PID.
- A `dns-proxy` process that survives `kill -9` is a zombie, not a running server.
- A killed `flock` wrapper can leave a child, such as `sleep`, holding the lock.
- Use `busybox nslookup` to test DNS. If its query never reaches the server, suspect
  the client's libraries first.

## Still to do

1. Install the `.bin` on the phone. The files are tested; the update itself is not.
2. Confirm the Settings key and find the remaining keys.
3. Start each game, and test incoming calls and the headset.
4. Find the real cause of the SIP stack byte, to replace the fixed address.
5. Drop `lcsD375` and its fonts from the image once the D815 app has proven itself.
   That saves several MB.
