#!/usr/bin/env python3
"""Check a digital capture of the phone's audio output against a ringtone (tests/ringtones.sh).

usage: ringtone_corr.py SOURCE.wav CAPTURE.raw [CAPTURE2.raw ...]
CAPTURE*.raw: S16LE mono 16 kHz from tools/rtcap. SOURCE.wav: 16-bit mono PCM (any rate).
Prints, per capture, the peak normalised cross-correlation of the source (resampled to
16 kHz) against the capture (FFT, numpy). Exit 0 if the best capture reaches >= 0.6.
"""
import sys, wave
import numpy as np

def load_wav(p):
    w = wave.open(p, 'rb')
    assert w.getsampwidth() == 2 and w.getnchannels() == 1, 'need 16-bit mono'
    r = w.getframerate()
    s = np.frombuffer(w.readframes(w.getnframes()), '<i2').astype(float)
    if r != 16000:
        t = np.arange(int(len(s) * 16000 / r)) * r / 16000
        s = np.interp(t, np.arange(len(s)), s)
    return s

def peak_ncc(src, cap):
    """max over lags of <src, cap[lag:lag+n]> / (|src| |cap[lag:lag+n]|)"""
    n = len(src)
    if len(cap) < n:
        cap = np.concatenate([cap, np.zeros(n - len(cap))])
    m = 1 << int(np.ceil(np.log2(len(cap) + n)))
    num = np.fft.irfft(np.fft.rfft(cap, m) * np.conj(np.fft.rfft(src, m)), m)[:len(cap) - n + 1]
    c2 = np.concatenate([[0.0], np.cumsum(cap * cap)])
    win = np.sqrt(np.maximum(c2[n:] - c2[:-n], 1e-9))
    r = np.abs(num) / (np.linalg.norm(src) * win)
    r[win < 1e-3 * win.max()] = 0  # ignore silent windows
    i = int(np.argmax(r))
    return float(r[i]), i / 16000

def main():
    src = load_wav(sys.argv[1]); best = 0.0
    for p in sys.argv[2:]:
        cap = np.frombuffer(open(p, 'rb').read(), '<i2').astype(float)
        rms = float(np.sqrt(np.mean(cap * cap))) if len(cap) else 0.0
        c, t = peak_ncc(src, cap) if rms > 0 else (0.0, 0.0)
        print('%s: %d samples, rms %.1f, peak ncc %.3f at %.3f s' % (p, len(cap), rms, c, t))
        best = max(best, c)
    print('MATCH' if best >= 0.6 else 'NO MATCH')
    sys.exit(0 if best >= 0.6 else 1)

if __name__ == '__main__':
    main()
