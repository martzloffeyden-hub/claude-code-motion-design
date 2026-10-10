#!/usr/bin/env python3
"""Visual + numeric QA of the soundtrack: spectrogram, loudness curve,
onset alignment against the timeline and click detection."""
import os, sys
import numpy as np
from scipy import signal
from scipy.io import wavfile
from PIL import Image, ImageDraw
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import timeline as TL

path = sys.argv[1]
out = sys.argv[2]
sr, x = wavfile.read(path)
x = x.astype(np.float64) / 2 ** 31
mono = x.mean(axis=1)
print("duration", len(mono) / sr, "sr", sr, "channels", x.shape[1])
print("peak dBFS", 20 * np.log10(np.abs(x).max()))
# spectrogram (log freq) image
f, t, S = signal.spectrogram(mono, sr, nperseg=4096, noverlap=4096 - 480, scaling="spectrum")
S = 10 * np.log10(S + 1e-14)
W, H = 1800, 500
fl = np.geomspace(20, 20000, H)
img = np.zeros((H, len(t)))
for i, ff in enumerate(fl):
    j = np.searchsorted(f, ff)
    img[H - 1 - i] = S[min(j, len(f) - 1)]
img = np.clip((img + 110) / 80, 0, 1)
im = Image.fromarray((img * 255).astype(np.uint8)).resize((W, H))
im = im.convert("RGB")
# rms curve
hop = int(sr * 0.01)
rms = np.array([np.sqrt(np.mean(mono[i:i + hop] ** 2)) for i in range(0, len(mono) - hop, hop)])
rdb = 20 * np.log10(rms + 1e-9)
canvas = Image.new("RGB", (W, H + 220), (10, 10, 10))
canvas.paste(im, (0, 0))
d = ImageDraw.Draw(canvas)
pts = [(i * W / len(rdb), H + 210 - (np.clip(v, -70, 0) + 70) * 3) for i, v in enumerate(rdb)]
d.line(pts, fill=(120, 220, 120), width=1)
events = {"EMERGE": TL.T_EMERGE, "ANAT": TL.T_ANATOMY, "DIST": TL.T_DISTORT, "COLL": TL.T_COLLAPSE,
          "BREATH": TL.T_BREATH, "IMPACT": TL.T_IMPACT, "TITLE": TL.T_TITLE, "FADE": TL.T_FADE}
for k, v in events.items():
    xx = v / TL.DURATION * W
    d.line([(xx, 0), (xx, H + 220)], fill=(255, 60, 60), width=1)
    d.text((xx + 3, H + 5), k, fill=(255, 120, 120))
canvas.save(out)
# onset alignment: first sample after each cut exceeding a sharp energy rise
env = np.abs(signal.hilbert(hp := signal.sosfilt(signal.butter(2, 30, "highpass", fs=sr, output="sos"), mono)))
for k, v in events.items():
    if k in ("TITLE", "FADE", "BREATH"):
        continue
    i0 = int((v - 0.05) * sr); i1 = int((v + 0.1) * sr)
    seg = env[i0:i1]
    base = np.median(env[int((v - 0.3) * sr):int((v - 0.06) * sr)]) if v > 0.4 else 0
    thr = max(seg.max() * 0.5, base * 3)
    on = i0 + np.argmax(seg > thr)
    print(f"{k:7s} cut {v:7.3f}s  onset {on / sr:7.4f}s  offset {1000 * (on / sr - v):+6.1f} ms")
# click detection: large 2nd-derivative spikes relative to local level
d2 = np.abs(np.diff(mono, 2))
loc = signal.lfilter([0.001], [1, -0.999], np.abs(mono))[2:] + 1e-4
ratio = d2 / loc
idx = np.where(ratio > 40)[0]
print("click-suspects:", len(idx), (idx[:20] / sr).round(3))
