# To test on the real phone

Things only a person at the D375 can check. Firmware installed 2026-11-02: the
merged CFW with the D815 app. Tick an item or add what you saw, and Claude
updates this file after every change.

## Calls

Calls worked before the install. The install replaced the whole rootfs and
SIP registration isn't confirmed yet, so one quick round is enough:

- [ ] Call the phone from another phone: it rings, pick up on the handset,
      audio both ways. That confirms SIP registration as well.
- [ ] Press the speaker key during that call.

## Keys

- [ ] Function keys: the left column is P1 to P5 and the right column is P6 to P10.
      Row 6 is P11 on the left and P12 on the right.
- [ ] Settings key opens the settings menu.
- [ ] Help key does something useful.
- [ ] The key with the download symbol (where "snom" used to be).
- [ ] Record key.
- [ ] Any key that does nothing: list it here.
      The phone logs it to `/snom/d815/tmp/unmapped-keys`.
- [ ] A script assigned to a key runs, and the key label shows the
      script's name, not `key-script?run=...`.

## Screen and LEDs

- [ ] Your custom boot splash appears while booting.
- [ ] The two red LEDs that used to stay on are off when idle.
- [ ] Each function key LED lights next to its own key.
- [ ] Backlight dims when idle and brightens on a key press.
- [ ] Idle screen widgets (new in this firmware) show and look right.

## Games

Each one should start from the phone menu and return to the phone app when you quit.

- [ ] Doom
- [ ] NES
- [ ] Game Boy Advance
- [ ] Game Boy
- [ ] Game sound plays at a normal volume.

## Tools

- [ ] `htop` runs in an SSH session. Expect a host key warning on the first
      login after the install.
- [ ] The CFW panel works in a browser: `http://192.168.178.72:8080/`.

## Speed

- [ ] Menus and key presses feel responsive. The load average stays near 5 while
      idle, which is still unexplained.
