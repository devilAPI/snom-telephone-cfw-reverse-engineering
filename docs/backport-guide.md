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
| Settings, Help and snom keys | Work | Injected presses open Einstellungen, Informationen and CFW Tools (2026-11-04) |
| Backlight | Works | 30 of 32 on a key press, dims to 6 after about 20 s (2026-11-04) |
| Icons, background, Contrast theme | Works | 0 `ToImage` errors |
| Side button panels | Native, five per side, with icons. Six per side is not possible: the layout is compiled in | Framebuffer capture |
| CFW scripts on keys | Works, and survives a reboot | Key 12 assigned from the web panel, phone rebooted, key pressed, script ran |
| Games menu | Works | Opens on the phone with its icon |
| Doom, NES, GB, GBA | Work: picture, quit with the red key, app back in about 30 s, no reboot | Test ROMs and Doom shareware, framebuffer captures (2026-11-04) |
| Games on keys | Works | NES game on key 5 started from an injected press (2026-11-04) |
| CFW panel on port 8080 | Works | Login, tabs and Logs tab in headless Chromium (2026-11-04) |
| Keys 11 and 12 | Work, with no LEDs and no side panel labels | Injected key events; see [Keys 11 and 12](#keys-11-and-12) |
| All other keys | Work | Every safe key code injected; none is unmapped (2026-11-04) |
| Incoming calls, headset | Untested | |

Keys with no D815 code are logged to `/snom/d815/tmp/unmapped-keys` with their D375
key code. Press the keys that do nothing, then read that file. The four keys the
shim sends through `phone-key` (Settings, Help, Rec and snom) are not logged: before
2026-11-04 they were, which made them look broken.

The idle load average of about 5 is not CPU use. Five kernel threads of the audio
driver (`hwthread`, `hausioctl`, `Cadence`, `EPTing_0`, `EPTing_2`, parent
`kthreadd`) wait in `down()`, an uninterruptible sleep, and kernel 2.6.27 counts
those in the load. The CPU is 87% idle. The `EPTing` threads get new PIDs each time
the app starts, so the app's audio endpoints create them.

The `.bin` was installed on the real phone on 2026-11-02. `tools/device/d815-try-flash.sh`
remains the fast way to test app changes.

## Build and test

`rootfs/d375` holds the full D375 CFW, so the D375 build does not use
`tools/fw/cfw-sync.sh`: it would replace the panel with the smaller `src/cfw/panel`.
Packing uses `rootfs/d375.manifest`, not a fakeroot database.

```sh
tools/fw/build-custom-firmware.sh      # FINAL=1 for the smallest image
tools/device/d815-try-flash.sh [phone-ip]  # try it on a phone, without a firmware update
```

`tools/fw/build-custom-firmware.sh` runs `tools/backport/stage.py`, adds the result to
the image, and updates the VM. To change the file selection, delete
`emu/backport/d8.tar` first so that `pack.py` runs again. After changing
`src/native/fb24shim.c`, run `tools/build/build-fb24shim.sh`.

`tools/device/d815-try-flash.sh` is the fast way to test: it copies the staged files to the
phone and reboots once into them. It also copies `rootfs/d375/snom/cfw/lib`,
`cgi-bin` and the game binaries over the installed ones. It takes about 4 minutes,
and the phone is registered about a minute after that. The next reboot runs the
installed firmware's `start.sh` again. The copied files stay on flash and take about 26 MB.

### Installing the image

Use the phone's Software Update page. Writing `/snom/update` by hand does not work:
rcS deletes it at boot and reads it only after the phone app exits. The update then
takes about 6 minutes.

The image is 55 MB, and the phone downloads it during boot into `/tmp`. Older CFW
builds set that to 40 MB, so the download fails on them, and a `mount -o remount` does
not survive that reboot. Change the size in rcS once, as root:

```sh
sed -i 's/-o remount,size=40M/-o remount,size=64M/' /etc/init.d/rcS
reboot
```

Current images set 64 MB themselves.

Extraction runs from the rescue filesystem, with its `tar` stderr going only to the
serial console. `tar` cannot replace a mount point, and one on the same flash makes it
stop with "Extracting Failed", leaving a mix of old and new files. `update/preSystemUpdate.sh`
in the image therefore unmounts everything under `/snom`, including the custom splash
bind from rcS. The phone is still reachable after a failed run: its web UI accepts
another signed image, and a tiny one with `update/systemUpdate`, `update/updateHelper.sh`
and the missing files repairs it.

To rehearse an image, run the rescue `tar` from `/dev/mtdblock4` in the VM, over the
extracted tree. JFFS2 shows up to 34 MB more used space until garbage collection runs.

### Going back to the D375 app

The original app is still in the image:

```sh
touch /snom/cfw-data/use-d375-app && reboot
```

Delete that file to return to the D815 app.

### Settings and login

The app writes settings to flash much later than it applies them, so a reboot can
lose a recent change. Adding `store_settings=save` to the request writes them at
once; `phone_set` does this.

The app keeps its settings in `/snom/snomconfig/d815`. The first boot copies the
phone's settings there, removes `setting_server`, sets the side panels to short
labels, and sets the web login to `admin` and the model's default password, `snom375` on a D375.
The original settings stay as they are, for the D375 app. To start again, delete
that folder and reboot.

### Testing from RAM

`tools/device/d815-on-d375.sh` is the older method. It runs the app from a RAM disk and
writes less to flash, but uses 49 MB of RAM and its web login is fixed. Use it only
for a change to the file selection on a phone with little free flash.

## How it fits together

| Part | File | Job |
|---|---|---|
| File selection | `tools/backport/pack.py` | Picks the app and its libraries, writes `d8.tar` |
| Staging | `tools/backport/stage.py` | Lays out `/snom/d815` and the extra icons |
| Boot | `src/cfw/app/start-d815.sh` | Sets up the chroot and config, starts `lid` |
| Hook | `tools/fw/cfw-sync.sh` | Makes `start.sh` run the boot script |
| Runtime shim | `src/native/fb24shim.c` | Loaded with `/etc/ld.so.preload`; adapts the hardware differences |
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
| Web panel keys fail | Same login | Use `phone-key` | `src/cfw/panel/cgi-bin/key` |
| Two apps on screen after quitting a game | Games and `phone-restore.sh` only knew `lcsD375` | Stop both names; stop and unmount the chroot; `start.sh` starts it again | game sources, `lib/phone-restore.sh` |
| Ringtone page cannot save | Web login | `rt_curl` reads the login from the app's settings | `lib/ringtones.sh` |
| Stuck on "Neuen HTTP-Benutzernamen eingeben" | No web credentials set | Add them to the app's config | `start-d815.sh` |
| All icons fail: `Can't get raw image` | Imlib2 loaders use `dlopen` | Add `usr/lib/imlib2/loaders` | `pack.py` |
| `No image found for icon type` | Theme or icon missing from flash | Add D815-only icons; link Contrast to Dark | `stage.py` |
| No host name resolves | `libnss_dns` is opened with `dlopen` | Add `libnss_dns`, `libnss_files` | `pack.py` |
| "SIP abgeschaltet" | `gsw120` switch sysfs is absent | Redirect it to `eth0`'s carrier and stand-in files | shim `redirect()` |
| Identity never registers | "Stack enabled" byte never gets set | Set the byte at runtime | shim `enable_sip_stack()` |
| Provisioning from the wrong URL | `setting_server` serves D375 files | Delete it from the app's config | `start-d815.sh` |
| `LD_PRELOAD` has no effect | `lid` clears the environment | Use `/etc/ld.so.preload` in the chroot | `stage.py` |
| Two red LEDs always on | They are GPIOs the D815 app never touches; it drives D815 pin numbers instead | Reset them at boot; map D815 GPIO 29 to 32 and 126 to 18; send other GPIO access to `/tmp/gpio` | shim `redirect_gpio()`, `start-d815.sh` |
| Settings pages answer 403 | The app leaves Administrator mode by itself | `phone_admin` logs in first | `lib/phone-web.sh` |
| Script keys labelled `key-script?run` | The panels show the short label | Set `fkey_short_label` too | `lib/key-scripts.sh` |
| Help and download keys do nothing | The stock app gives them no function, and `HELP`/`SNOM` do nothing here | Open Informationen and CFW Tools with `minibrowser.htm` | shim, `phone-key` |
| `htop` missing | It was only built on `main` | Add it to the tree | `rootfs/d375/usr/bin/htop` |
| High idle CPU | See Performance | | |
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

### Keys 11 and 12

The D375 has 12 P keys and the app shows 10 on a page. P11 and P12 are the first
two keys of the app's page 2, and they are `fkey10` and `fkey11` in the settings.

| Part | How it works | Where |
|---|---|---|
| Key press | `lid` has names for P11 and P12 but no key codes. Codes 80 and 69 go through it as P10, and the shim changes the name in its `KEYS` message | `keymap.py`, shim `send()` |
| Phone menu | The Smart Label entry opens one list of 12 keys, not the page list | `stage.py`, `pkeys.xml` |
| Web page | One instruction changes from 10 rows to 12. `stage.py` checks the build first | `stage.py`, `lcsD815` |
| LEDs | Not supported. The app only writes LEDs for the page on screen, so the shim turns 11 and 12 off | shim `clear_extra_leds()` |

The web page keeps its page list, and Pages 3 and 4 have no physical keys.

The on-screen side panels stay at 5 rows per side, so they show no labels for P11
and P12. The layout is compiled in: about 120 tests of the number 5 in the panel
code, and each page's data is packed for 5 entries. Six rows would mean changing
the size of the app's objects, which cannot be done without its source.

`settings=apply` is not limited to RAM: the app can write the value to `config.xml`
later. When testing a setting, put the old value back with `settings=save`.

### Icons

`stage.py` adds the 30 D815-only icons to `/snom/bmp`, and makes
`theme_contrast` a tree of real folders holding symlinks to the Dark icons. The app
does not follow symlinked folders, but symlinked files are fine. The chroot then
needs only one bind mount of `/snom/bmp`.

## Performance

Idle CPU, measured per thread on the phone over 10 s:

| | Main thread | Screen copier |
|---|---|---|
| Before | 17% | 8% |
| After | 11% | 2% |

- The identity tile scrolled because `user@192.168.178.1` was too wide once the
  panels took their space. Every step redrew it through a temporary PNG, about 28
  file opens per second. `user_idle_text1` now shows the short user name. A long name
  brings this back, so keep it short.
- The copier now checks the screen 5 times a second once it has stood still for
  about half a second, and 20 times a second otherwise.
- `/etc/localtime` was missing, so the app retried it about 10 times a second. The
  chroot now has a small UTC file.

## Which physical key is which

The app shows five keys per side, and the D375 has six. So that each key sits next
to its label, `keymap.py` moves the right column up by one, and the shim moves its
LEDs to match:

| Physical key | App key | Label on screen |
|---|---|---|
| Left rows 1 to 5 | P1 to P5 | Left panel |
| Right rows 1 to 5 | P6 to P10 | Right panel |
| Left row 6 | P11 | None |
| Right row 6 | P12 | None |

Row 6 has no status LED either: the app does not report a state for P11 and P12.

The same app key numbers are used in the settings, so a key's number in the phone
menu is the app key above, not the number printed for the D375.

## Running a script from a key

Scripts live in `/snom/cfw-data/scripts`. To put one on a key:

- **Web panel:** Scripts, Manage scripts, Phone keys.
- **Phone:** Settings, CFW Tools, Scripts, Assign to a key.

Either way, the key becomes the phone's own `url` function, pointing at
`http://127.0.0.1:8081/cgi-bin/key-script?run=NAME.sh`, and is labelled with the
script's name. It can also be seen and changed in the phone's normal key settings.

The script runs in the background with the usual 20 s limit, and the phone shows
nothing. Its last output is in `/tmp/key-script.log`. The code is in
`lib/key-scripts.sh`, and `lib/phone-web.sh` holds the login handling.

## Porting to another model

Work through these in order. Steps 2 to 6 need nothing from the phone.

1. **Get the firmware.** `tools/fw/fw-unpack.sh` works only with keys that are already
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
- `mount --bind` works on folders but not on single files here. Use
  `/snom/cfw/bin/bindmount`.
- `tools/device/d815-try-flash.sh` needs a way to get the SSH password. Without a terminal, set
  `SSH_ASKPASS` and `SSH_ASKPASS_REQUIRE=force`, or it exits with 255 and no message.
- `busybox httpd` reads an `httpd.conf` it finds in its web root. Keep the panel login
  in `/etc/cfw-httpd.conf`, or the loopback server on 8081 asks for a login too.
- A killed `flock` wrapper can leave a child, such as `sleep`, holding the lock.
- Use `busybox nslookup` to test DNS. If its query never reaches the server, suspect
  the client's libraries first.

## Still to do

1. Confirm the Settings key and find the remaining keys.
2. Start each game, and test incoming calls and the headset.
3. Find the real cause of the SIP stack byte, to replace the fixed address.
4. Drop `lcsD375` and its fonts from the image once the D815 app has proven itself.
   That saves several MB.
