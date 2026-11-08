# Running firmware in QEMU

QEMU has no machine for either phone's SoC, so this repo adds two. They boot the
firmware without replacing its kernel: the stock kernel, its modules, `rcS`,
`lid` and the phone app all run from your build.

| | D375 | D815 |
|---|---|---|
| Machine | `snom-d375` (`emu/board/snom_d375.c`) | `snom-d815` (`emu/board/snom_d815.c`) |
| SoC | Broadcom BCM11107, ARM1176 | DSP Group DVF99, ARM926 |
| Kernel | 2.6.27 | 3.4.112-rt, device tree |
| Boots | CFW `.bin` | CFW `.ubifs` |
| Screen | Yes | Yes |
| SSH | `-p 12222`, password `snom375` | `-p 13222`, password `snom815` |
| CFW panel | `http://127.0.0.1:18080/`, login `root` | `http://127.0.0.1:19080/`, login `root` |
| Phone web UI | `http://127.0.0.1:18081/` | `http://127.0.0.1:19081/` |
| Keyboard input | Yes, see below | Yes, see below |
| Root shell socket | `emu/run/d375/shell.sock` | `emu/run/d815/shell.sock` |

Neither model has audio or calls.

## virt-manager

```sh
tools/qemu/build-qemu.sh     # once: downloads QEMU 11.1.2 and builds it
tools/qemu/vm-define.sh      # once: registers snom-d375 and snom-d815
```

In virt-manager, use File > Add Connection > "QEMU/KVM user session". The VMs are
listed there; they are not on the default system connection.

Both firmware build scripts finish by running `tools/qemu/vm-update.sh`, so the next
VM boot runs the newest build. The VM definitions point at fixed paths in
`emu/vm/<model>/` and never need editing. To load a different image by hand:

```sh
tools/qemu/vm-update.sh d375 path/to/image.bin
tools/qemu/vm-update.sh d815 path/to/rootfs.ubifs
```

An update replaces the flash, so changes made inside the guest are lost. A VM that
is running keeps its old flash until it is shut down.

Speed, measured on the D375 VM: SSH is up 73 seconds after the first boot of a
fresh flash, and 35 seconds on later boots. The first boot is slower because of
the first-boot cleanup and SSH key generation. Once running, the VM matched or beat
the real phone on 5 of 6 benchmarks; only process creation was slower, by 16%.

libvirt reports these VMs as tainted (`custom-argv`). That is expected: flash and
networking have no libvirt device type, so they are passed as raw QEMU arguments.

## Without libvirt

```sh
tools/qemu/qemu-run.sh d375               # GTK window, serial on stdout
tools/qemu/qemu-run.sh --headless d815    # LCD on VNC 127.0.0.1:5975
```

Do not run this and the VM for the same model at once: they share ports and flash.

`socat - UNIX-CONNECT:emu/run/d375/shell.sock` gives the root shell.

## Keyboard in the VM window

| Key | D375 | D815 |
|---|---|---|
| Up, Down | Yes | Yes |
| Enter | OK | OK |
| Esc | Cancel | Back |
| F1 | Call History | Call History |
| F2 | Directory | Directory |
| F3 | Settings | Function key panel |
| 1 to 6 | Digits | None yet |

Left, Right and digits 7 to 0 are not mapped. These codes were found by pressing
each one in the running app. They differ from the names in `docs/doom.md`: in
`lcsD375`, OK is 102 and Up is 116, while Doom calls 97 OK and 84 Up.

`virsh send-key snom-d375 --codeset linux 28` presses Enter from a script.

The D375 image runs the D815 phone app ([backport-guide.md](backport-guide.md)). A
fresh VM stops at its language wizard, because it has no saved settings. The web UI
login is `admin` / `snom375`.

## D375: what is emulated

`emu/board/snom_d375.c` is the whole machine. The memory map and interrupt
numbers come from `arch/arm/mach-bcmring` in Linux 3.0. The closed drivers were
read from the disassembly.

| Block | State |
|---|---|
| CPU, 256 MB DDR | ARM1176, same MIDR as the phone. The kernel's `PHYS_OFFSET` is 0x200000 |
| Interrupts, UARTs | QEMU's PL190 and PL011 |
| Timers | Four SP804 channels, each with its own interrupt |
| NAND + UMI | K9F1G08 model, persisted to `emu/vm/d375/nand.img` |
| DMA | DesignWare AHB, memory-to-memory and linked lists |
| Ethernet | Datapath only, on top of DMA. No switch or PHY behaviour |
| LCD | 480x272 BGRX scanout from UPBASE |
| Keypad | Full matrix |
| RNG | Real random data; `rngd` needs it or `sshd` blocks on `/dev/random` |
| Everything else | `snom-iostub`: reads return the last write |

To see what the stub is being asked for, add `-d unimp -D file` to QEMU. The first
access to each address is logged.

## D375: what differs from a real phone

`tools/qemu/qemu-mkflash.py` changes two things in the flash image. The `.bin` file
itself is not modified.

1. **`/snom/media_daemon` is replaced by a stub.** The real one needs the voice
   DSP (VPM), which runs code QEMU cannot execute, so `ept_core` fails to start
   and `media_daemon` exits. Without a peer `lcsD375` shows "MediaStack
   restarting". The stub accepts its LPCP connection on `127.0.0.1:1299`, logs
   commands to `/tmp/mediaipc.log` and never replies.
2. **`rcS` starts a root shell on UART B** before it loads modules.

Consequences:

- No audio and no calls. Anything using `halaudio`, the DSP or `media_daemon`
  cannot be tested here, so game sound work still needs the phone.
- Doom and the NES emulator are untested in QEMU.
- `/protected` holds a placeholder, not the phone's certificate data.
- The VPM phase status is deliberately left wrong, so the DSP load fails at once.
- USB fails to start: OHCI times out, with no model behind it.
- The 2D engine (GE), SD and the real switch are stubs.
- Ethernet frames can carry up to 7 trailing pad bytes.
- The first-run wizard does not complete. After a few ENTER presses `lcsD375`
  restarts and returns to Language. The cause has not been investigated.

## D815: what is emulated

The kernel keeps its symbols, so the closed drivers were read with their real
function names; the device tree gave the address map.

| Block | State |
|---|---|
| CPU, 512 MB DDR | ARM926 at 0x40000000 |
| PLICU interrupts, UARTs, RTC | Own models. The RTC is `sched_clock` |
| Timer | QEMU's SP804 |
| NAND | Sequencer model, 256 MiB, persisted to `emu/vm/d815/nand.img` |
| Ethernet | QEMU's `npcm-gmac`, the same Synopsys GMAC. The PHY is the kernel's fixed PHY |
| LCD | 480x272, 24-bit |
| Everything else | The same register stub as the D375 |

`tools/qemu/vm-update.sh d815` patches a copy of the device tree to turn off the Vivante
GPU, the `dvf9a` analog chip and the DSA switch, and to set a MAC address.

## D815: what differs from a real phone

`tools/qemu/qemu-mkubi.py` does the job of `ubinize`. It adds a prebuilt `overlay`
volume from `emu/d815-overlay/`, and the firmware's own `unionfs` mount places those
files over `/snom`. The rootfs itself is not modified. The overlay holds:

1. A `media_daemon` stub, for the same reason as on the D375.
2. A `start.sh` that also opens a root shell on UART 1.

Consequences:

- No audio or calls: the CSS voice DSP does not run, and `app_dsp` crashes at boot.
- USB and the display's frame interrupt are not modelled; the kernel logs timeouts
  for both.
- The flash has no MTD partitions, so `ubi.mtd=0` covers the whole device and rcS
  steps that use `/dev/mtdblock5` or `fw_printenv` fail harmlessly.
- `/protected` is absent.

The first-run wizard has not been tested on the D815.

### Permissions in rootfs/d815

`rootfs/d815/` has no execute bits at all. A UBIFS built straight from it
cannot boot: the kernel gets `EACCES` on `/sbin/init` and panics with "No init
found". `tools/fw/build-d815-ubifs.sh` avoids this by extracting the stock image as
root in Docker and copying in only the files that differ. New CFW files added to
that tree are copied too, and keep the non-executable mode of the tree, so set
their mode in that script.

## Troubleshooting

- **Port already in use**: QEMU refuses to start if a forwarded port is taken.
  Change `PORT_*` in `tools/qemu/qemu-args.sh`, then run `tools/qemu/vm-define.sh` again.
- **Silent after "Uncompressing Linux"**: the log is still in RAM until the UART
  driver probes. `pmemsave` the RAM and search for `<5>Linux version`.
- **D815 console**: with libvirt it is in `emu/run/d815/console.log`.
- **Serial log looks empty to grep**: it contains NUL bytes; use `grep -a`.
