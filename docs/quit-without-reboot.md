# Quit a game without rebooting the phone

Until now, quitting Doom or the NES emulator **rebooted the phone** (~2 min) to
bring the phone UI and call audio back, because "media_daemon won't restart by
hand". It turns out a reboot isn't needed: the stock phone app restarts cleanly
in about **30 s** once a few orphaned processes from the takeover are gone.

    /snom/cfw/lib/phone-restore.sh     exit 0 = phone app healthy again
                                       exit 1 = not healthy in 60 s (caller reboots)

The launchers (`doom/boot-doom.sh`, `nes/boot-nes.sh`) call it after the engine
exits and only fall back to `reboot` if it fails. Other launchers (GB/GBA,
ringtones, …) should do the same:

```sh
touch /tmp/ssh_fast_update          # before the engine's snd_hal_init() kills lid
"$ENGINE" ...
if ! /snom/cfw/lib/phone-restore.sh; then
    rm -f /tmp/ssh_fast_update; sync; reboot
fi
```

Env knobs: `RESTORE_TIMEOUT` (s, default 60), `RESTORE_LOG` (default
`/tmp/phone-restore.log`, one line per step with the uptime).

## What the takeover leaves behind

`snd_hal_init()` (snd/snd_hal.c) arms the codec, injects the speaker key, then
`kill -9 lid media_daemon` with `/tmp/ssh_fast_update` held. The process tree
before and after (from `/proc/<pid>/stat`, stock 10.1.64.17):

| process | parent | after `kill -9 lid media_daemon` |
|---|---|---|
| `rcS` (`startUpApplication`) | init | waits in `while [ -f /tmp/ssh_fast_update ]; do sleep 1; done` |
| `lid` (+ a 2nd `lid` thread-process) | rcS (via `start.sh`'s `exec ./lid`) | dead |
| `media_daemon --log -1 --rec 0 --play 0` | lid | dead |
| `lcsD375 --root-dir /snom/` (the UI) | lid | **orphan, keeps running** (Doom `SIGSTOP`s it) |
| `bsa_server --all=0` (Bluetooth) | lid | **orphan** |
| `dns-proxy` (uid 99) | lcsD375 | **orphan** |

What each orphan holds (from `/proc/net/tcp`, `/proc/<pid>/fd`):

- `media_daemon` listens on **127.0.0.1:1299**; `lcsD375` connects to it.
- `lcsD375` listens on **127.0.0.1:1298**; `bsa_server` connects to it.
- `dns-proxy` listens on **127.0.0.1:53** (udp+tcp); `/etc/resolv.conf` has
  `nameserver 127.0.0.1` first.

A new `lid` starts new copies of all of these. With the old ones still alive the
new `lcsD375` can't bind 1298 and the new `dns-proxy` can't bind 53 (observed: a
second `dns-proxy` that runs with **no sockets at all** while the orphan keeps
the port). So the orphans must die *before* `lid` restarts.

The kernel side needs nothing: once the game's halaudio fd and the daemon's fds
are closed, `/proc/halaudio` shows `Clients: total=0`, the EPT kernel threads
(`EPTegrRTP_*`, `EPTing_*`) are gone, and the restarted `media_daemon` re-creates
them and all `amxr` routes (`/proc/amxr`: `halaudio.apm0/1 <-> ept.bind0/1`,
`pcm0 <-> ept.bind_nb0`) exactly as at boot.

## Why "media_daemon won't restart by hand"

Reverse engineering of the stock `lid` (Ghidra via REA, 10.1.64.17):

- `lid` starts the daemon itself (`FUN_000587d0`): `fork()`, stdout/stderr to
  `/dev/null`, `sched_setscheduler(SCHED_RR, prio 95)`, then
  `execve("/snom/media_daemon", ["--log","-1","--rec","0","--play","0"(,"--no_handset_agc","--no_headset_agc")], envp=NULL)`
  (the agc flags depend on the `handset_agc`/`headset_agc` settings).
- Right after starting it, `lid` **kills its UI child with SIGKILL**
  (`FUN_0003739c`: `start_media_daemon(); …; kill(lcs_pid, 9)`) — `lid` always
  restarts `lcsD375` together with a fresh `media_daemon`. The UI only talks to
  a `media_daemon` it connected to at its own start (TCP 1299).

So a `media_daemon` started by hand (without `lid`, next to an orphaned
`lcsD375` whose connection to the old daemon is dead) runs, but nothing ever
drives it: no UI → no tones, no calls. That is what looked like "it won't
restart". Restarting the **whole** app through `lid` is the right unit.

`lid` also has a stock "restart the phone app" path: on **SIGUSR1** it prints
`Got SIGUSR1, do_restart_phone_app()` and (`FUN_0003a9b0`) syncs, SIGKILLs
`lcsD375`, sends **SIGINT** to `media_daemon` (`FUN_00058a80`), SIGKILLs
`bt_ag_server`, stops `bsa_server`, and `_exit(1)`s. Verified live: after
`kill -USR1 <lid>` only `dns-proxy` (a grandchild) survives. With the flag held,
rcS then waits; removing the flag restarts `lid`. We can't use SIGUSR1 for the
*takeover* (a clean SIGINT shutdown of `media_daemon` would power down the
hands-free route that snd_hal relies on, see [sound.md](sound.md)), but it
confirms that "kill the children, let rcS restart `lid`" is the stock design.

## The restore, step by step (`lib/phone-restore.sh`)

1. If `lid` is still running (the game failed before the takeover): `SIGCONT`
   `lcsD375`, drop the flag, done once healthy.
2. If `lid` is dead **and the flag is gone**, rcS has already left its loop
   (it then runs the update/reboot path) — nothing to restore, exit 1.
3. `SIGCONT` + `SIGKILL` every `lcsD375 bsa_server dns-proxy bt_ag_server
   media_daemon`, wait until they're gone (≤3 s). (SIGKILL is what `lid` itself
   uses on `lcsD375`.)
4. `rm /tmp/ssh_fast_update`. Within 1 s rcS's `sleep 1` loop ends and it runs
   `/snom/start.sh` → `exec ./lid`. `lid` immediately shows its own
   "Starting phone application." screen.
5. Wait (≤ `RESTORE_TIMEOUT`) until **healthy** = `lid`, `media_daemon`,
   `lcsD375` running and 127.0.0.1:1299 (media_daemon) and :1298 (lcsD375)
   listening.

Timeline measured on the phone (uptime deltas after dropping the flag):

| t | event |
|---|---|
| 0–1 s | rcS restarts `start.sh`, `lid` up, boot-style splash on screen |
| ~1–23 s | `lid` initialises (network/settings; same pause as at boot — not shortened) |
| ~24 s | `media_daemon` starts, 1299 listening, EPT threads back |
| ~26 s | `lcsD375` starts |
| ~27–30 s | 1298 listening → **healthy**; idle screen shortly after |
| a few s later | `dns-proxy` back on :53, SIP re-registers |

## Test

`tests/restore.sh` (under the phone lock): two full rounds through the real
launcher `boot-nes.sh` with `tests/roms/tone.nes` (`SND_VOL=5`), quit by
injecting the red hangup key (scancode 114) into `/dev/input/event0`, then
checks: restore `< 30 s`, uptime keeps growing (no reboot), SIP `Identity 1`
status equal to the pre-game value, and audio:

**Audio check without listening.** `tests/helpers/amxrtap` (a 2 KB freestanding
ARM binary, raw syscalls, builds with plain clang — command in its header)
connects the amxr source port **`ept.bind1`** (what the DSP sends to the
loudspeaker codec `halaudio.apm1`) to `amxruser.bind0` (stock
`amxr_user_hook.ko`, insmod'ed if needed and removed again), and records 300
frames (1.5 s). The test sets `vol_speaker=1`, presses SPEAKER (hands-free dial
tone), records, hangs up and restores the old volume. Idle → RMS 0; dial tone at
volume 1 → RMS ≈ 100. Disconnect is amxr ioctl `'M',54` (`0x800c4d36`, the
API-table entry after `amxrConnect`); verified in `/proc/amxr` that the tap
connection is gone afterwards.

## Gotchas

- **Order matters**: kill the orphans *before* dropping the flag. Otherwise the
  new `dns-proxy` starts without its port (DNS silently falls back to the second
  nameserver) and the new `lcsD375` can't bind 1298.
- **Never drop the flag while `lid` is dead and you're not ready**: rcS restarts
  `lid` within a second. And never let `lid` die *without* the flag: rcS leaves
  its loop and the phone goes down the update/reboot path.
- The game process must have exited (fb, `event0` and the halaudio fd closed)
  before calling the script — the launchers call it after the engine returns.
- `phone-restore.sh` exits 1 rather than hanging; the launchers then reboot as
  before, so the worst case is the old behaviour.
- The kernel log shows nothing new on a restore (`Booting TL3 processor` stays
  at one occurrence from boot): the EPT/DSP kernel drivers stay loaded and just
  get a new client; only user space restarts.
- Doom `SIGSTOP`s `lcsD375`; the script `SIGCONT`s and `SIGKILL`s it (a stopped
  process dies on SIGKILL anyway; verified with a stopped `lcsD375`, restored in
  27 s).
