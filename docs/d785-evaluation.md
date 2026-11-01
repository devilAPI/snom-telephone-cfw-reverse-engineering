# D785 as a backport base

Status: static analysis only, done 2026-11-01. Nothing here was run on a phone or
a VM. See [backport.md](backport.md) for the D815 experiment this compares with.

## Result

**Keep the D815 as the base, and try turning the panels off with its settings
first.** Take the D785's `media_daemon` as a part, because it may remove the
hardest remaining job, audio.

The D785 does not lack mappable keys. It has them on a second, separate display,
so they are not on the main screen. On a D375 that display does not exist.

| Question | Answer |
|---|---|
| Easier way to remove the panels | D815 settings: `smartlabel_idle_default=off`, `smartlabel_call_default=off` |
| Technically closest to the D375 | D785: ARMv6, same kernel, same audio stack, similar key codes |
| Better base overall | D815 for now. It already runs, keeps 10 of the 12 key IDs, and has the longer future |
| When to switch to the D785 | If `off` leaves panels on screen, or the D785 app needs no pixel shim and that matters |

The settings test is much cheaper than a base change, and its result decides
whether the base change is needed at all.

## Firmware used

| | |
|---|---|
| Image | `orig_firm/snomD785-10.1.226.16-SIP-r.bin` (was already in the repo, untracked) |
| SHA-256 | `18de584de4fe39a4772fca6c57ff28d355c5a070f0f006f3922f328e3bbb7eac` |
| Unpacked to | `decrypted/D785-10.1.226.16/` |
| Method | `tools/fw-unpack.sh` with `keys/snomD785-firmware1.pub`, unchanged |
| Signature | Verified with that key, so the image is genuine snom firmware |

No download was needed, and no key was recovered or derived.

`lcsD785` is packed with UPX 3.96, unlike `lcsD815` and `lcsD375`. `start.sh` tries
`upx -d`, but the image contains no `upx`. See [Unpacking lcsD785](#unpacking-lcsd785).

## Comparison

| | D375 10.1.64.17 | D785 10.1.226.16 | D815 10.1.226.16 |
|---|---|---|---|
| App target | ARMv6 | ARMv6 (uses `ldrex`, `uxtb`, `rev`) | ARMv5TE |
| ABI | EABI5 soft-float | EABI5 soft-float | EABI5 soft-float |
| glibc shipped | 2.19 | 2.19 | 2.19 |
| Highest symbol needed | GLIBC_2.8 | GLIBC_2.17 | GLIBC_2.17 |
| `libstdc++` | 6.0.24 | 6.0.32 | 6.0.32 |
| Minimum kernel in the binary | 2.6.16 | 2.6.16 | 2.6.16 |
| Own kernel | 2.6.27.47 | **2.6.27.47** | 3.4.112-rt |
| SoC family | bcmring | **bcmring** | dvf99 |
| Main screen | 480x272 | **480x272**, hardcoded check | Runs at 480x272 |
| Second display | None | 254x100 ST7586S on `/dev/fb1` | None |
| Media protocol | LPCP/1.2 | LPCP/1.2 | LPCP/1.2 |
| `lcs` build date | | Jul 10 2026 | Jul 10 2026 |

The libraries that `lcs` links are the same set on D785 and D815 (gRPC, protobuf,
Abseil, gloox 18), except that the D815 also uses `libnl`.

## Where the panels come from

The left and right columns appear to be **smart labels**. This is inferred from
the code and settings; the panels were not looked at on a phone.

- The layout is **compiled in**: `LabelPanel` and `SmartLabelDisplay` in `lcs`.
- XML supplies the menus and the content, not the layout. Editing XML will not
  remove them.
- All GUI XML is the same on D785 and D815 except for three files that exist on
  one model only (`bluetooth.xml`, `usb_bluetooth.xml`,
  `center_align_call_terminated.xml`). `state_idle.xml`, `smart_labels.xml` and
  `pkeys.xml` are identical.

### D815: settings can switch them off

`smart_labels.xml` and `smartlabel.htm` offer these:

| Setting | Values | Meaning |
|---|---|---|
| `smartlabel_idle_default` | `off`, `short`, `half`, `full` (or on/off) | Idle screen |
| `smartlabel_idle_expanded` | `short`, `half`, `full` | Alternative idle mode |
| `smartlabel_idle_trigger` | Empty means off | What opens the alternative mode |
| `smartlabel_call_default` | `off`, `short`, `half`, `full` | Call screen |
| `smartlabel_call_trigger`, `smartlabel_other_trigger` | Empty means off | Triggers on other screens |

To try it, set both `*_default` to `off` and the triggers to empty. The web page is
`smartlabel.htm`; the phone menu is Preferences, Display, smart labels.

Two limits:

- `run-d8.sh` copies `snomconfig` into the RAM chroot, so a change made there is
  lost at reboot. It has to be applied to that copy at each start.
- The physical keys should keep working, but with no labels.

Not known: the shipped default of each setting, and whether `off` frees the space
for the rest of the screen or only blanks the columns.

### D785: labels go to the second display

The strings show the difference between the models:

| | D785 | D815 |
|---|---|---|
| Label class | `LabelDisplay` and `SmartLabelDisplay` | `SmartLabelDisplay` only |
| Label keys | `SMARTLABEL_WITHOUT_KEYS` | `SMARTLABEL_WITH_KEYS` |
| Label page keys | `HAS_LABEL_PAGE_NEXT_KEY` | `NOT_HAS_LABEL_PAGE_NEXT_KEY` |
| Label backlight | `label_backlight`, `/sys/class/backlight/snom2` | None |
| Label screenshot | `label_screen.bmp` | None |

The kernel confirms the hardware: `drivers/video/fb_snom_st7586S2.c`, `snom_spi`,
and `keypad0`/`keypad1` device nodes.

The constructor at `0x36ff34` in the unpacked `lcsD785` picks the device:

| Index | Device | Expected size |
|---|---|---|
| 1 | `/dev/fb1` | 254x100 |
| Other | `/dev/fb0` | 480x272 |

A failed `open` logs `Can't open device '%s'`, sets a flag and returns. A wrong
size logs `Wrong display dimensions`. Neither aborts in that function. The D375
kernel has no such driver, so `/dev/fb1` will not exist there. What the rest of
the app does with that flag was **not traced**. If it misbehaves, the shim can
offer a fake `fb1` of 254x100.

So with no `fb1`, the fkey labels should simply be invisible. Smart labels could
still appear on the main screen, because the feature exists in the D785 too. The
same settings apply there.

## Pixel format

**Open question.** It could not be settled from the code.

- All three apps size the `mmap` the same way: `xres * yres * bpp / 8` from
  `FBIOGET_VSCREENINFO`. No model-specific depth constant was found.
- Between the D785 and D375 kernels, the display strings that differ are the extra
  ST7586S and backlight driver. The main LCD driver's strings match.

That suggests `/dev/fb0` on a D785 is the same as on a D375, and that `lcsD785` may
need no pixel conversion. It does not prove it. The D815 app needed the shim because
it drew 24-bit, so a real run has to show this. If the D785 app draws 32-bit, the
20 Hz copy thread in `fb24shim.c` goes away, but the key translation stays.

## Keys

`tools/backport/keymap.py` works unchanged on the D785 `lid`.

| | D375 | D785 | D815 |
|---|---|---|---|
| Entries in the switch table | 118 | 118 | 44 |
| Distinct key IDs | 52 | 42 | 44 |
| D375 codes with the same ID | | 34 of 52 | 1 |
| D375 IDs with no equivalent | | 12 | 8 |
| D375 codes with no target | | 13 | 7 |
| P-key style IDs | `A`-`L` | `A`-`F`, plus `(` and `)` | `A`-`J` |

The key tables favour the D785 for codes and the D815 for the number of keys. On
the D815 two of the D375's twelve keys have no ID. On the D785 six have none,
presumably because it has six keys with label paging. That reading of the IDs is an
inference: the IDs were read from the tables, not matched to physical keys.

The D785 also needs a `(` and `)` decision, for example giving those page IDs to two
of the spare keys.

## Audio and media_daemon

This is the most useful result. `docs/backport.md` rates audio as hard and expects
a translating proxy, because the D815 app and the D375 `media_daemon` disagree.

The disagreement is the same for both newer apps:

| | Format |
|---|---|
| D375 `lcs` | `SetupAudioDevice: %s %d - %s %d %d - %s` |
| D785 and D815 `lcs` | `SetupAudioDevice: %s %d %d %d %s %d %d %s` |
| D375 `media_daemon` | `onSetupAudioDevice: %d %d - %d %d - %d` |
| D785 and D815 `media_daemon` | `onSetupAudioDevice: %d %d - %d %d - %d-%d-%d` |

The LPCP verb lists barely differ. Against the D375 `lcs`, the D785 adds three
Wi-Fi verbs and the D815 adds those plus three `3CXSBC` verbs. So **switching to
`lcsD785` alone does not fix audio.**

The D785 `media_daemon` looks like a good fit for D375 hardware:

| Check | Result |
|---|---|
| Architecture | ARMv6, VFPv3, like the D375 one |
| Linked audio libraries | The same 7 |
| Those 7 libraries | **Byte-identical to the D375's** |
| Kernel modules | 86 of 88 identical; the other two are `halaudio_usb` and `halaudio_usbcore` |
| Module vermagic | Identical (`2.6.27.47 preempt mod_unload ARMv6`) |
| New runtime need | D785's `libstdc++` (GLIBCXX_3.4.32) |

It is built from the same release as both newer apps and has the matching
`SetupAudioDevice` format. It could therefore replace the D375 daemon and pair with
**either** app, with no proxy. That is why it helps even if the D815 stays the base.

Not known: whether it applies acoustic settings that suit a D785 rather than a D375,
such as gain, echo cancelling and handset tuning. No model names appear in its
strings, but it does contain tuning-related ones, such as `IS_HIGH_SPEAKER_GAIN`.
The binary format matching does not show the audio will sound right. Test at 5%
amplitude.

## Size and RAM

Measured with the `tools/backport/pack.py` selection, with `lcsD785` swapped in.
Totals are file sizes in MiB.

| | D785 | D815 |
|---|---|---|
| `lcs` | 15.0 unpacked (4.6 packed) | 15.6 |
| `lid` | 2.0 | 0.7 |
| Selected files | 46.3, using unpacked `lcs` | 46.0 |
| Icons missing from the D375 flash | 34 (0.01) | 30 (0.25) |

Both fit in the 62 MB tmpfs with about 16 MB to spare. The full-rootfs sizes (137 MB
and 179 MB) do not matter, since the selection is what ships.

Run `lcsD785` **unpacked**. Packed, its 15 MB of code would be decompressed into
anonymous memory on top of the 4.6 MB file in tmpfs. It should use about as much
RAM as `lcsD815` (about 30 MB resident was measured on the phone), but that figure
is **not measured** for the D785.

## Other hardware paths

`lcsD785` wants `/sys/class/backlight/snom` and `snom2`, `lcsD815` wants `dvf9a-bl`,
and the D375 has `lcdfb-bl`. Neither matches, so both need the same kind of fix.

## Age and updates

| | D785 | D815 |
|---|---|---|
| Firmware today | 10.1.226.16 | 10.1.226.16 |
| Announced | Older model | New D81x series, with 10.1.184.14 (2024) |
| Kernel | 2.6.27.47, built Dec 2022 | 3.4.112-rt |

The two are the same release from the same day, so a D785 base gives up nothing
today. The difference is the future. A third-party tracker lists D785 support ending
on 2027-12-01, but it contradicts itself on other dates, and snom's own lifecycle
page was not found. Treat that date as unconfirmed. No lifecycle date was found for
the D815. Being the newer series, it should outlast the D785, which is an assumption.

Either way the base is a closed binary running on kernel 2.6.27. An update only
helps while each new release still runs there. Note that `lcsD815` needs ARMv5 only,
so it does not depend on the D785 line staying alive.

Sources:
[eol.network: D785](https://eol.network/snom/d-series/D785-/-D785N),
[ip-phone-forum: firmware 10.1.184.14](https://www.ip-phone-forum.de/threads/snom-firmware-10-1-184-14-release-vom-27-september-2024.319916/).

## Next steps

In this order, each on the phone, using the phone lock:

1. In the D815 stack, set the `smartlabel_*` values above and look at the idle and
   call screens. This answers the main question.
2. Run the D785 `media_daemon` on the D375, with its `libstdc++`, and connect
   `lcsD815` to it. Check `SetupAudioDevice` first, then a call at 5% amplitude.
3. Only if step 1 fails: run `lcsD785` with no `fb1`, and look at the colours, the
   panels and the keys.

## Verified and assumed

| Verified from the files | Inferred or assumed |
|---|---|
| Signature, version, build dates | The panels are smart labels |
| ARMv6 code, kernel versions | `off` frees the screen space |
| 480x272 and 254x100 checks in the code | `lcsD785` draws 32-bit |
| Non-fatal `fb1` failure in the constructor | The rest of the app copes without `fb1` |
| XML and settings contents | `A`-`L` are the physical P keys |
| Key tables, LPCP verbs, format strings | D785 `media_daemon` runs and sounds right on a D375 |
| Library and module hashes | RAM use of `lcsD785` |
| File sizes | D785 and D815 lifecycle dates |

## Unpacking lcsD785

Use `upx -d` from a trusted install when one is available. In this evaluation it
was not installed, so the file was unpacked as data by a small script. That script
is not kept in the repo.

Two things are easy to get wrong when doing it by hand:

- Blocks use NRV2E_8. The main block has filter `0x50`, which rewrites **every**
  4-aligned word whose top byte ends in `0xB`, not just `0xEB`. Handling only `0xEB`
  leaves text damaged with no error: "auto_key_config" reads as "au..key_config".
  The check used was that 16018 strings matched the D815, up from 14953.
- The third block is the data segment. It belongs at file offset `0xed3200`, not
  straight after the code.

The result has no section table, which the loader does not need.
