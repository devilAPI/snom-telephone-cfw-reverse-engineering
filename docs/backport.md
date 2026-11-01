# Backporting newer firmware to the D375

Status: experiment only. Nothing here is part of a CFW build.

The D375 stops at 10.1.64.17. The D815 has 10.1.226.16. The closed apps cannot be
patched from source, so a backport means running the D815 binaries on the D375.

## Why it can work

| | D375 10.1.64.17 | D815 10.1.226.16 |
|---|---|---|
| glibc | 2.19 | 2.19 |
| Minimum kernel in the binaries | 2.6.16 | 2.6.16 |
| CPU target | ARMv6 | ARMv5, which ARMv6 also runs |
| Media protocol | LPCP/1.2 | LPCP/1.2 |

## Experiment

On the D375 VM, with the D375 `lid` paused and `lcsD375` killed, the D815 `/lib`,
`/usr/lib`, `/bin`, `/sbin`, `/etc` and `/snom` files were put in a RAM disk. The
D815 `lid` was then started in a `chroot`, with a stub `media_daemon`.

| Result | |
|---|---|
| All libraries load on kernel 2.6.27 | Yes |
| `lid` starts `lcsD815` and it stays up | Yes, about 2 minutes observed |
| Web UI on port 80 | Answers `302`, as on a D815 |
| Screen | Draws, but garbled: 24-bit output on a 32-bit framebuffer |
| Memory | App about 32 MB resident, on the VM's 256 MB |
| Keys, calls, audio, setup, real hardware | **Not tested** |

Stopping `lid` makes `rcS` reboot, so pause it with `kill -STOP`. The VM hangs on
reboot because the reset is not modelled.

## Real phone test

`lcsD815` was run once on a real D375, from a 50 MB RAM disk with no `/dev/mtd*`
and no flash tools in the `chroot`, with an automatic reboot armed.

| Result | |
|---|---|
| `lid` starts `lcsD815` on real hardware | Yes, about 90 seconds observed |
| Web UI | Answers `302` |
| Connection to the real D375 `media_daemon` on port 1299 | Stays established |
| Screen | Draws, but 24-bit on the 32-bit panel, so it is garbled |
| Memory | About 30 MB resident, 3 MB free plus page cache |
| Physical keys | Reported working by eye during the run; not measured |
| Audio, calls | Not tested |

**The phone has 120 MB of usable RAM, not the 256 MB of the VM.** That run held 50 MB
in a RAM disk; from flash the same files would not use that RAM, but expect far less
headroom than the VM suggests.

## Pixel format shim

`lcsD815` draws 24-bit pixels, while the D375 panel is 32-bit. `tools/fb24shim.c`
intercepts `open`, `ioctl` and `mmap` on `/dev/fb0`: the app gets a 24 bpp shadow
buffer, and a thread copies changed lines to the real framebuffer 20 times a
second. The app writes red first and the panel wants blue first, so it swaps them.

Build it with `tools/build-fb24shim.sh`. Load it through `/etc/ld.so.preload`
inside the chroot, because `lid` clears the environment and `LD_PRELOAD` never
reaches the app.

Tested in the D375 VM and on a real D375: the image is clean and full width, with
`lcsD815` connected to the real `media_daemon`. Colours were not checked on a full
theme, since that test set leaves the theme images out.

## Running this on a phone

- Do not leave the D375 `lid` paused for long. It feeds the kernel's software
  watchdog, which reboots the phone after about a minute without it.
- Killing `lid` makes `rcS` reboot. Resuming it after killing `lcsD375` also reboots.
- The working setup replaces `/snom/start.sh`, so no D375 `lid` runs at all.
- A one-shot `start.sh` must restore the original with `mv`, not `cat >`. The shell
  reads the script while running it, so overwriting the file in place makes it
  continue with the original's last lines, which start the normal `lid`.
- `eth0` stays down until `lid` starts it, so SSH needs it brought up by hand.

## Keys, icons and config

The D815 app is now the D375 CFW's phone app. It boots with the phone's own config,
registers and makes calls. The current state, every fix and the steps for other
models are in [backport-guide.md](backport-guide.md).

Three things cost the most time:

- Imlib2 and glibc open libraries with `dlopen`, which `pack.py` could not see. That
  caused the missing icons and the broken DNS.
- The app reads the D815's Ethernet switch from sysfs and showed "SIP abgeschaltet"
  while that failed.
- Registration stayed off until the shim set the "SIP stack enabled" byte itself.
  This depends on a fixed address, so it fits only this build of the app.

## What a real backport needs

| Part | Difficulty | Work |
|---|---|---|
| Screen | Done in the VM | `tools/fb24shim.c`, see below |
| Update path | Medium | The image is about 90 MB, but the update lands in a 40 MB `/tmp`. Needs a larger `/tmp` first, or a two-step update |
| Model identity | Medium | The app believes it is a D815: name, settings, provisioning |
| Keys and LEDs | Medium | Remap D375 key codes to what `lcsD815` expects; check `/dev/snomled` |
| Audio and calls | **Hard, unknown** | Keep the D375 `media_daemon` for its DSP. Both speak LPCP/1.2, but commands differ, including `SetupAudioDevice` and `muteStream`. Likely a small translating proxy on port 1299. Only testable on the phone |
| Features tied to D815 hardware | Accept the loss | Wi-Fi association, its Bluetooth and USB audio paths |

Every shim is a guess about closed code, and each new snom release can break it.

## Cheaper options

1. Update individual components, such as OpenSSH, BusyBox or CA certificates, as
   static builds.
2. Add the wanted feature as CFW instead of as the D815 app.
3. Check what a newer version actually gives before investing: the two differ in
   18 GUI XML files plus 5 that exist in only one, and the D815 adds `obuspa`.

The D385 10.1.226.16 image would be the better source, but it cannot be opened: its
key is not available.
