#!/usr/bin/env python3
"""Check an snd_hal PCM dump (SND_DUMP=1 -> /tmp/snd_dump.raw, S16LE mono 16 kHz)
for expected tones.

usage: fftcheck.py DUMP.raw CONST_HZ ARP_HZ[,ARP_HZ...]

Splits the dump into 100 ms windows (skipping silence), finds the strongest
spectral peaks in each and checks that
  * CONST_HZ is among the top peaks in most non-silent windows, and
  * every arpeggio note is the strongest-or-second peak in at least one window.
Prints a per-window summary and RMS level; exits 1 on failure.
"""
import sys
import numpy as np

RATE = 16000

def peaks(x, n=3):
    w = x * np.hanning(len(x))
    spec = np.abs(np.fft.rfft(w, 8 * len(x)))
    freqs = np.fft.rfftfreq(8 * len(x), 1 / RATE)
    spec[freqs < 60] = 0
    out = []
    for _ in range(n):
        i = int(np.argmax(spec))
        out.append(freqs[i])
        lo, hi = max(0, i - 40), i + 40          # notch out +-25 Hz around it
        spec[lo:hi] = 0
    return out

def near(f, g, tol=0.03):
    return abs(f - g) <= tol * g

def main():
    raw = np.fromfile(sys.argv[1], dtype='<i2').astype(np.float64)
    const = float(sys.argv[2])
    arp = [float(f) for f in sys.argv[3].split(',')]
    win = RATE // 10
    print('dump: %.1f s, peak %d, rms %.0f' % (len(raw) / RATE, np.max(np.abs(raw)) if len(raw) else 0,
                                               np.sqrt(np.mean(raw ** 2)) if len(raw) else 0))
    loud = [raw[i:i + win] for i in range(0, len(raw) - win, win)
            if np.sqrt(np.mean(raw[i:i + win] ** 2)) > 20]
    if len(loud) < 10:
        print('FAIL: fewer than 10 non-silent windows (%d)' % len(loud)); return 1
    have_const = 0
    seen = set()
    for k, x in enumerate(loud):
        p = peaks(x)
        if any(near(f, const) for f in p): have_const += 1
        for a in arp:
            if any(near(f, a) for f in p[:2]): seen.add(a)
        if k < 12: print('  win %2d: peaks %s' % (k, ' '.join('%6.1f' % f for f in p)))
    ok = True
    frac = have_const / len(loud)
    print('constant %.1f Hz in %d/%d windows (%.0f%%)' % (const, have_const, len(loud), 100 * frac))
    if frac < 0.6: ok = False
    missing = [a for a in arp if a not in seen]
    print('arpeggio notes found: %s; missing: %s' % (sorted(seen), missing))
    if missing: ok = False
    print('PASS' if ok else 'FAIL')
    return 0 if ok else 1

if __name__ == '__main__':
    sys.exit(main())
