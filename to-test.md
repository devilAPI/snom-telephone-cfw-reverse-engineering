# To test on the real phone

Things only a person at the D375 can check. Firmware installed 2026-11-02: the
merged CFW with the D815 app. Tick an item or add what you saw, and Claude
updates this file after every change.

Everything Claude could check remotely was tested on 2026-11-04 and is listed
under [Already checked remotely](#already-checked-remotely) at the end. What is
left needs eyes, ears or hands.

## Calls

SIP registration is confirmed ("Registriert", also after the game tests and a
reboot). Audio can't be checked remotely:

- [ ] Call the phone from another phone: it rings, pick up on the handset,
      audio both ways.
- [ ] Press the speaker key during that call.

## Keys

- [ ] Rec key during a call. At idle it does nothing, which is expected.
- [ ] One real press of each special key: Settings, Help, and the key with the
      download symbol. Injected presses work; this confirms the physical keys.

## Screen and LEDs

- [ ] Your custom boot splash appears while booting. The right file is in
      place; only the boot screen itself can't be captured.
- [ ] The two red LEDs that used to stay on are off when idle.
- [ ] Each function key LED lights next to its own key. Press DND (right column,
      top) to light one, and press it again to turn DND off.

## Games

- [ ] Game sound plays at a normal volume. The tests ran at volume 5 of 100, so
      nothing was audible.
- [ ] A game feels playable with the real keys.

## Speaker (sound from the PC to the phone)

New on 2026-11-04, not in the installed firmware yet: it's on the phone through SSH, so
it is there until the next flash, and in the next image. Recorded with the phone's own
mic it works; what is left is how it sounds.

- [ ] Panel, tab Phone, card "Speaker / reverse intercom": Start, pick a music file,
      Play file. It plays on the phone's loudspeaker, clean and at a sensible volume
      (start with volume 30).
- [ ] On the PC, `tools/device/snom-speaker.sh` (asks for the panel password). Pick "snom
      D375" as the output and play something. Is the delay OK (about 0.2 s)?
- [ ] Speaker and intercom at the same time: talk through the phone from the PC and
      listen to the phone in the panel.
- [ ] After the sound stops there is no hiss from the speaker (it mutes after 2 s).
- [ ] **Handset output (experimental):** panel, Speaker card, Output "Handset earpiece",
      play a file, then lift the handset. Do you hear it in the earpiece (maybe with the
      dial tone)? With the handset on the cradle, can you hear it at all? A remote
      test could not confirm either. Set the output back to Loudspeaker after.
- [ ] Music from the PC plays without cracks or skips, also loud songs. You heard
      cracks and skips on 2026-11-04; fixed the same day, see docs/speaker.md
      "Real-time priority". If it still happens, open
      `http://PHONE:8091/status?k=TOKEN` and note `missed_frames`, `underruns` and
      `dropped_ms`.

## Navidrome player

New on 2026-11-04, on the phone through SSH and in the next image. Tested against a
throwaway Navidrome with test tones (`tests/navidrome.sh`); your own server and real
music are left.

- [ ] Panel, tab Phone, card Navidrome, Server settings: your server's http:// address,
      user, password, "Save and test" says "saved, the server answers".
- [ ] Phone: Menu, CFW Tools, Navidrome: Artists, an album, a track plays. Sound is
      clean (it's 16 kHz mono, so like a good phone call, not hi-fi).
- [ ] Pause / Resume continues at the same place; Next and Previous; Stop.
- [ ] Search with the keypad finds an artist.
- [ ] The menus feel fast enough (0.5 to 4 s per press on the test).
- [ ] With `tools/device/snom-speaker.sh` running, the Navidrome music still plays (both are
      mixed).

## Speed

- [ ] Menus and key presses feel responsive.

## Already checked remotely

Tested 2026-11-04 with injected key events (`keyinject`), framebuffer captures
(`fbshot`) and the phone's own web pages.

- SIP identity 1 registered.
- Function keys: left P1 to P5, right P6 to P10, left row 6 P11, right row 6 P12.
  Every key was given a test script and pressed. The right column triggers
  keys 6 to 10 and its labels sit next to it.
- A script on a key shows the script's name as its label.
- Settings opens Einstellungen, Help opens Informationen, and the download-symbol
  key opens CFW Tools.
- No key is unmapped. The unmapped-keys log listed Settings, Help, Rec and the
  snom key, which the shim handles itself; it no longer logs them.
- The backlight goes to 30 of 32 on a key press and dims to 6 after about 20 s.
- Doom, NES, Game Boy and GBA each start, draw their picture, quit with the red
  key, and the phone app is back in about 30 s with no reboot.
- Games on keys: a NES game on key 5 got the label "tone", started from the key,
  and the key went back to a line key when cleared.
- The panel answers 401 without the login and 200 with it. Its tabs and the Logs
  tab work in a browser, with the live view and filter.
- The system log has the phone app's messages.
- `htop` runs over SSH.
- The load average of about 5 is explained and harmless: five kernel threads of
  the audio driver (`hwthread`, `hausioctl`, `Cadence`, `EPTing_0`, `EPTing_2`)
  sleep in an uninterruptible wait, and this kernel counts those in the load.
  They use no CPU, and the CPU is 87% idle.
- Speaker: a tone sent to the phone is played on the loudspeaker and found in a recording
  by the intercom mic, 460 times above the noise; a 2 s sound takes 2 s; from the PC
  script live with about 0.1 s buffered and no dropouts; the intercom keeps its full
  speed while both run; stop cleans up (`tests/speaker.sh`).
- Idle screen widgets are known not to work on this phone (see
  `docs/idle-screen.md`), so they are no longer on this list.
