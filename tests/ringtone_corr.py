#!/usr/bin/env python3
"""Check a capture of the phone's audio against a ringtone (tests/ringtones.sh).

usage: ringtone_corr.py SOURCE.wav CAPTURE.raw [CAPTURE2.raw ...]
CAPTURE*.raw: S16LE mono 16 kHz from tools/rtcap. SOURCE.wav: 16-bit mono PCM (any rate).

The ringer does not pass through the amxr graph, so the capture comes from the microphones
(acoustic loopback at ringer volume 1 and a 5 % amplitude file): the waveform is buried in
room noise and the speaker/mic response, so a sample-level correlation is meaningless.
Instead we compare log-magnitude spectrograms (50 ms frames, 300-3000 Hz, each frequency
row normalised against its own median = "how far above the noise floor"), then take the
best normalised correlation over all time lags. Exit 2 if every capture is all-zero
(the on-hook mic path is not always powered, see docs/ringtones.md). Exit 0 if the best capture is >= 0.25 (measured: right file ~0.37, a different
tone pattern ~0.09, room noise ~0.03).
"""
import sys, wave
import numpy as np

N = 800  # 50 ms at 16 kHz

def load_wav(p):
    w = wave.open(p, 'rb')
    assert w.getsampwidth() == 2 and w.getnchannels() == 1, 'need 16-bit mono'
    r = w.getframerate()
    s = np.frombuffer(w.readframes(w.getnframes()), '<i2').astype(float)
    if r != 16000:
        t = np.arange(int(len(s) * 16000 / r)) * r / 16000
        s = np.interp(t, np.arange(len(s)), s)
    return s

def spec(x):
    f = np.array([np.abs(np.fft.rfft(x[k:k + N] * np.hanning(N)))
                  for k in range(0, len(x) - N + 1, N)])
    f = f[:, 15:150]                         # 300 .. 3000 Hz
    f = np.log1p(f / (np.median(f, axis=0) + 1e-9))
    return f - f.mean()

def score(src, cap):
    a, b = spec(src), spec(cap)
    best, lag = 0.0, 0
    for k in range(0, max(1, len(b) - len(a) + 1)):
        w = b[k:k + len(a)]
        if len(w) < len(a): break
        w = w - w.mean()
        c = float((a * w).sum() / (np.linalg.norm(a) * np.linalg.norm(w) + 1e-9))
        if c > best: best, lag = c, k
    return best, lag * N / 16000

def main():
    src = load_wav(sys.argv[1]); best = 0.0; heard = False
    for p in sys.argv[2:]:
        cap = np.frombuffer(open(p, 'rb').read(), '<i2').astype(float)
        rms = float(np.sqrt(np.mean(cap * cap))) if len(cap) else 0.0
        c, t = score(src, cap) if rms > 0 else (0.0, 0.0)
        print('%s: %d samples, rms %.1f, spectrogram ncc %.3f at %.2f s' % (p, len(cap), rms, c, t))
        best = max(best, c); heard = heard or rms > 0
    if not heard:
        print('SILENT (microphones not active: capture inconclusive)'); sys.exit(2)
    print('MATCH' if best >= 0.25 else 'NO MATCH')
    sys.exit(0 if best >= 0.25 else 1)

if __name__ == '__main__':
    main()
