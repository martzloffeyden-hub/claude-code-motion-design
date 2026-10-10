#!/usr/bin/env python3
"""QA of the delivery file: container/stream specs, full decode, frame
count, and audio/video sync measured on the encoded file itself."""
import json
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import timeline as TL  # noqa: E402

path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(HERE), "output", "SINGULARITY.mp4")


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


info = json.loads(run(["ffprobe", "-v", "error", "-count_frames", "-show_streams", "-show_format",
                       "-of", "json", path]).stdout)
v = next(s for s in info["streams"] if s["codec_type"] == "video")
a = next(s for s in info["streams"] if s["codec_type"] == "audio")
fmt = info["format"]
print("== container ==")
print(f"  format     {fmt['format_name']}  size {int(fmt['size']) / 1e6:.1f} MB  bitrate {int(fmt['bit_rate']) / 1e6:.2f} Mb/s")
print(f"  duration   {float(fmt['duration']):.3f} s")
print("== video ==")
print(f"  codec      {v['codec_name']} ({v.get('profile')}, level {v.get('level')})")
print(f"  size       {v['width']}x{v['height']}  pix_fmt {v['pix_fmt']}  color {v.get('color_space')}/{v.get('color_primaries')}/{v.get('color_transfer')} {v.get('color_range')}")
print(f"  fps        r={v['r_frame_rate']} avg={v['avg_frame_rate']}  frames {v.get('nb_read_frames')}  duration {float(v['duration']):.3f} s")
print("== audio ==")
print(f"  codec      {a['codec_name']} ({a.get('profile')})  {a['sample_rate']} Hz  {a['channels']} ch  {int(a.get('bit_rate', 0)) / 1000:.0f} kb/s  duration {float(a['duration']):.3f} s")

err = run(["ffmpeg", "-v", "error", "-i", path, "-f", "null", "-"]).stderr.strip()
print("== full decode ==", "clean" if not err else err[:500])

# --- video: per-frame mean luma on a small proxy
W, H = 96, 54
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-vf", f"scale={W}:{H},format=gray", "-f", "rawvideo", "-"],
                     capture_output=True).stdout
frames = np.frombuffer(raw, dtype=np.uint8).reshape(-1, H, W).astype(np.float32)
luma = frames.mean(axis=(1, 2))
print(f"  decoded {len(luma)} frames; first frame luma {luma[0]:.2f}, last frame luma {luma[-1]:.2f}")
# --- audio
pcm = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "f32le", "-ac", "2", "-ar", "48000", "-"],
                     capture_output=True).stdout
st = np.frombuffer(pcm, dtype=np.float32).reshape(-1, 2).astype(np.float64)
au = st.mean(axis=1)
print(f"  decoded audio {len(st) / 48000:.3f} s, stereo sample peak {20 * np.log10(np.abs(st).max() + 1e-12):.2f} dBFS")
# global offset of the encoded audio against the master WAV (cross-correlation)
master = os.path.join(os.path.dirname(HERE), "audio", "singularity_48k.wav")
if os.path.exists(master):
    from scipy.io import wavfile
    from scipy import signal as _sg
    _, m = wavfile.read(master)
    m = m.astype(np.float64).mean(axis=1) / 2 ** 31
    L = min(len(m), len(au))
    c = _sg.fftconvolve(au[:L], m[:L][::-1], mode="full")
    lag = int(np.argmax(c)) - (L - 1)
    print(f"  encoded audio vs master WAV: offset {lag} samples ({1000 * lag / 48000:+.2f} ms)")

print("== sync (cut = luminance jump on the picture, onset = audio attack) ==")
cuts = [("act II", TL.T_EMERGE), ("act III", TL.T_ANATOMY), ("act IV", TL.T_DISTORT),
        ("act V", TL.T_COLLAPSE), ("impact", TL.T_IMPACT)]
dl = np.abs(np.diff(luma))
from scipy import signal
lpf = signal.sosfilt(signal.butter(4, [30, 220], "bandpass", fs=48000, output="sos"), au)
env = np.abs(signal.hilbert(lpf))
for name, t in cuts:
    f = int(round(t * TL.FPS))
    win = range(max(f - 6, 1), min(f + 6, len(luma)))
    fj = max(win, key=lambda k: dl[k - 1])     # frame where the jump lands
    vt = fj / TL.FPS
    i0, i1 = int((t - 0.03) * 48000), int((t + 0.30) * 48000)
    seg = env[i0:i1]
    k = int(np.argmax(seg > 0.5 * seg.max()))
    at = (i0 + k) / 48000
    print(f"  {name:8s} expected {t:7.3f}s | picture cut at frame {fj} ({vt:7.3f}s) | impact (low band, 50%) {at:7.3f}s | A-V {1000 * (at - vt):+6.1f} ms")
