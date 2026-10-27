#!/usr/bin/env python3
"""Replays saved recordings through the overlay's level meter (same math as
Sources/MowaCore/LevelMeter.swift) and prints the tallest bar per second, so you can see
whether the strip changed because the *audio* got quieter (microphone) or not.

  python3 scripts/meter-check.py               # last 10 recordings in build/dev-recordings
  python3 scripts/meter-check.py <folder> ...  # specific recording folders
"""
import json, os, sys, wave
import numpy as np

FLOOR_DB, FULL_DB = -52.0, -28.0

def load(path):
    w = wave.open(path)
    raw = w.readframes(w.getnframes())
    a = np.frombuffer(raw, dtype=np.int16 if w.getsampwidth() == 2 else np.float32).astype(np.float32)
    if w.getsampwidth() == 2: a /= 32768
    return a, w.getframerate()

def bars(a, sr, buf=1024, interval=0.07):
    per = max(1, round(interval * sr / buf)); out = []; pk = 0.0; c = 0
    for i in range(0, len(a) - buf + 1, buf):
        r = float(np.sqrt(np.mean(a[i:i + buf] ** 2)))
        lvl = min(1, max(0, (20 * np.log10(max(r, 1e-7)) + 60) / 60))
        pk = max(pk, lvl); c += 1
        if c == per: out.append(pk); pk = 0.0; c = 0
    return [min(1, max(0, (l * 60 - 60 - FLOOR_DB) / (FULL_DB - FLOOR_DB))) for l in out], interval * per

def main():
    root = os.path.join(os.path.dirname(__file__), '..', 'build', 'dev-recordings')
    dirs = sys.argv[1:] or [os.path.join(root, d) for d in sorted(os.listdir(root))[-10:]]
    for d in dirs:
        wav = os.path.join(d, 'audio.wav')
        if not os.path.exists(wav): continue
        meta = json.load(open(os.path.join(d, 'meta.json')))
        a, sr = load(wav)
        b, dt = bars(a, sr)
        n = max(1, round(1 / dt))
        secs = [max(b[i:i + n]) for i in range(0, len(b) - n + 1, n)]
        mic = meta.get('settings', {}).get('microphone', '')
        print(f"{os.path.basename(d)}  {mic}")
        print('   tallest bar per second (%):', ' '.join(f"{int(s*100):3d}" for s in secs))

if __name__ == '__main__':
    main()
