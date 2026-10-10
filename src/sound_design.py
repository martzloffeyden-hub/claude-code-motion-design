#!/usr/bin/env python3
"""SINGULARITY — original sound design, 100% synthesized (no samples).

Everything is generated from oscillators, noise, filters, modal resonators
and synthetic convolution reverbs, and placed on the shared timeline so
each impact lands exactly on its picture cut.

Output: audio/singularity_48k.wav (48 kHz, 24-bit, stereo, 36.000 s)
"""
import os
import sys

import numpy as np
from scipy import signal
from scipy.io import wavfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import timeline as TL  # noqa: E402

SR = 48000
N = int(round(TL.DURATION * SR))
RNG = np.random.default_rng(20261010)

# buses (stereo): dry, hall send, cathedral send
DRY = np.zeros((2, N))
HALL = np.zeros((2, N))
CATH = np.zeros((2, N))
# elements that must survive the silence of the breath (mixed after the gating)
POST_DRY = np.zeros((2, N))
POST_HALL = np.zeros((2, N))
_POST = [False]


# ----------------------------------------------------------------- helpers --
def s2i(t):
    return int(round(t * SR))


def tvec(dur):
    return np.arange(int(round(dur * SR))) / SR


def pan_gains(p):
    """constant-power pan, p in [-1, 1] (scalar or array)."""
    a = (np.asarray(p) + 1.0) * np.pi / 4.0
    return np.cos(a), np.sin(a)


def place(sig, t0, pan=0.0, gain=1.0, hall=0.0, cath=0.0, width=0.0):
    """Mix a mono (or stereo 2xN) signal into the buses at time t0."""
    sig = np.asarray(sig, dtype=np.float64)
    i0 = s2i(t0)
    if sig.ndim == 1:
        gl, gr = pan_gains(pan)
        st = np.vstack([sig * gl, sig * gr])
        if width > 0:
            # Haas-style decorrelation for width
            d = int(0.011 * SR)
            st[1] = (1 - width) * st[1] + width * np.concatenate([np.zeros(d), st[1][:-d]]) if len(sig) > d else st[1]
    else:
        st = sig
    if i0 < 0:
        st = st[:, -i0:]
        i0 = 0
    n = min(st.shape[1], N - i0)
    if n <= 0:
        return
    st = st[:, :n] * gain
    if _POST[0]:
        POST_DRY[:, i0:i0 + n] += st
        POST_HALL[:, i0:i0 + n] += st * max(hall, cath * 0.5)
        return
    DRY[:, i0:i0 + n] += st
    if hall:
        HALL[:, i0:i0 + n] += st * hall
    if cath:
        CATH[:, i0:i0 + n] += st * cath


def noise(n, color="white"):
    w = RNG.standard_normal(n)
    if color == "white":
        return w
    if color == "pink":
        b, a = [0.049922035, -0.095993537, 0.050612699, -0.004408786], [1, -2.494956002, 2.017265875, -0.522189400]
        return signal.lfilter(b, a, w) * 3.5
    if color == "brown":
        x = np.cumsum(w)
        x = signal.lfilter([1, -1], [1, -0.9995], x)
        return x / (np.std(x) + 1e-9)
    raise ValueError(color)


def bp(x, lo, hi, order=2):
    sos = signal.butter(order, [lo, hi], btype="bandpass", fs=SR, output="sos")
    return signal.sosfilt(sos, x)


def lp(x, f, order=2):
    sos = signal.butter(order, f, btype="lowpass", fs=SR, output="sos")
    return signal.sosfilt(sos, x)


def hp(x, f, order=2):
    sos = signal.butter(order, f, btype="highpass", fs=SR, output="sos")
    return signal.sosfilt(sos, x)


def sweep_filter(x, f_of_t, kind="lowpass", q=0.707, block=256):
    """Time-varying biquad (RBJ) processed in small blocks."""
    y = np.zeros_like(x)
    z = np.zeros(2)
    n = len(x)
    for i in range(0, n, block):
        f = float(np.clip(f_of_t[min(i + block // 2, n - 1)], 20.0, SR * 0.45))
        w0 = 2 * np.pi * f / SR
        alpha = np.sin(w0) / (2 * q)
        c = np.cos(w0)
        if kind == "lowpass":
            b = np.array([(1 - c) / 2, 1 - c, (1 - c) / 2])
        elif kind == "highpass":
            b = np.array([(1 + c) / 2, -(1 + c), (1 + c) / 2])
        else:  # bandpass (constant peak gain)
            b = np.array([alpha, 0.0, -alpha])
        a = np.array([1 + alpha, -2 * c, 1 - alpha])
        b, a = b / a[0], a / a[0]
        seg = x[i:i + block]
        out, z = signal.lfilter(b, a, seg, zi=z)
        y[i:i + block] = out
    return y


def env_adsr(n, a, d, s, r, sustain_len):
    """attack/decay/sustain/release in seconds -> envelope of length n."""
    e = np.zeros(n)
    ia, idd, isus, ir = s2i(a), s2i(d), s2i(sustain_len), s2i(r)
    k = 0
    seg = np.linspace(0, 1, max(ia, 1), endpoint=False); e[k:k + len(seg)] = seg[:n - k]; k += len(seg)
    if k < n:
        seg = np.linspace(1, s, max(idd, 1), endpoint=False); m = min(len(seg), n - k); e[k:k + m] = seg[:m]; k += m
    if k < n:
        m = min(isus, n - k); e[k:k + m] = s; k += m
    if k < n:
        seg = np.linspace(s, 0, max(ir, 1)); m = min(len(seg), n - k); e[k:k + m] = seg[:m]; k += m
    return e


def osc_phase(freq):
    """phase (radians) from an instantaneous frequency array."""
    return 2 * np.pi * np.cumsum(freq) / SR


def additive_saw(freq, nharm=40, bright=1.0, fmax=6000.0):
    ph = osc_phase(freq)
    out = np.zeros_like(freq)
    fmean = float(np.mean(freq))
    for k in range(1, nharm + 1):
        if k * fmean > fmax:
            break
        out += np.sin(k * ph) * (1.0 / k) * np.exp(-(k - 1) * 0.06 / bright)
    return out


def softclip(x, drive=1.0):
    return np.tanh(x * drive) / np.tanh(drive)


# --------------------------------------------------------------- reverbs --
def make_ir(dur, rt60_low, rt60_high, predelay=0.02, density_seed=1, er=True):
    n = int(dur * SR)
    t = np.arange(n) / SR
    rng = np.random.default_rng(density_seed)
    ir = np.zeros((2, n))
    bands = [(20, 250, rt60_low), (250, 1500, (rt60_low + rt60_high) / 2), (1500, 6000, rt60_high),
             (6000, 16000, rt60_high * 0.6)]
    for ch in range(2):
        acc = np.zeros(n)
        for lo, hi, rt in bands:
            nb = rng.standard_normal(n)
            nb = bp(nb, lo, min(hi, SR * 0.45), order=2)
            acc += nb * np.exp(-6.91 * t / rt)
        # gentle fade-in of the diffuse tail
        acc *= 1 - np.exp(-t / 0.012)
        if er:
            for k in range(14):
                d = predelay + rng.uniform(0.004, 0.09)
                acc[int(d * SR)] += rng.uniform(-1, 1) * 0.6 * np.exp(-d * 8)
        pd = int(predelay * SR)
        acc = np.concatenate([np.zeros(pd), acc[:-pd]])
        ir[ch] = acc
    ir /= np.max(np.abs(ir)) + 1e-9
    ir /= np.sqrt(np.sum(ir ** 2) / 2)
    return ir


def convolve_bus(bus, ir):
    out = np.zeros_like(bus)
    for ch in range(2):
        y = signal.fftconvolve(bus[ch], ir[ch])[:N]
        out[ch] = y
    return out


# =============================================================== SOUNDS ===
def boom(t0, size=1.0, pitch=1.0, metal=True, pan=0.0):
    """Cinematic impact: sub drop + punch + crack + giant metal resonance."""
    dur = 2.5 + 3.0 * size
    t = tvec(dur)
    f = (32.0 + (105.0 - 32.0) * np.exp(-t / 0.22)) * pitch
    sub = np.sin(osc_phase(f)) * np.exp(-t / (0.9 + 1.4 * size)) * (1 - np.exp(-t / 0.002))
    sub = softclip(sub * 1.6, 1.4)
    body = bp(noise(len(t), "pink"), 45, 420, 2) * np.exp(-t / 0.13) * 1.6
    crack = hp(noise(len(t)), 2500, 2) * np.exp(-t / 0.025) * 0.35
    snd = sub * 1.0 + body + crack
    place(snd * size, t0, pan=pan, gain=0.9, hall=0.25, cath=0.55 * size)
    if metal:
        base = 46.0 * pitch
        ratios = [1.0, 1.474, 2.093, 2.556, 3.17, 4.31, 5.62, 7.04]
        m = np.zeros(len(t))
        for i, r in enumerate(ratios):
            dec = (3.2 - 0.3 * i) * (0.6 + 0.4 * size)
            m += np.sin(2 * np.pi * base * r * t + RNG.uniform(0, 6.28)) * np.exp(-t / max(dec, 0.3)) / (1 + 0.45 * i)
        m *= (1 - np.exp(-t / 0.01))
        place(m * 0.16 * size, t0, pan=pan, width=0.8, hall=0.3, cath=0.7)


def reverse_swell(t_end, dur, lo=200, hi=6000, gain=0.5, pan=0.0):
    """Reverse-reverb style inhale that cuts exactly at t_end."""
    t = tvec(dur)
    x = noise(len(t), "pink")
    tt = t / dur
    f = lo * (hi / lo) ** (tt ** 1.5)
    y = sweep_filter(x, f, "bandpass", q=0.9)
    y += sweep_filter(noise(len(t), "white"), f * 1.5, "bandpass", q=2.0) * 0.4
    e = (tt ** 3.0) * (1 - np.exp(-(1 - tt) * SR / 200.0))
    place(y * e * gain, t_end - dur, pan=pan, width=0.6, hall=0.4)


def whoosh(t0, dur, f0=300, f1=3000, gain=0.3, pan0=-0.7, pan1=0.7):
    t = tvec(dur)
    tt = t / dur
    bell = np.sin(np.pi * tt) ** 2
    f = f0 * (f1 / f0) ** np.sin(np.pi * tt * 0.5)
    y = sweep_filter(noise(len(t), "pink"), f, "bandpass", q=1.2) * bell
    pans = pan0 + (pan1 - pan0) * tt
    gl, gr = pan_gains(pans)
    place(np.vstack([y * gl, y * gr]) * gain, t0, hall=0.2)


def clank(t0, size=1.0, pan=0.0, seed=0):
    """Heavy mechanical lock: modal metal + thump + hiss."""
    rng = np.random.default_rng(100 + seed)
    t = tvec(2.5)
    m = np.zeros(len(t))
    freqs = rng.uniform(180, 2600, 14)
    for f in freqs:
        dec = rng.uniform(0.12, 1.1) * (600 / f) ** 0.4
        m += np.sin(2 * np.pi * f * t + rng.uniform(0, 6.28)) * np.exp(-t / dec) * rng.uniform(0.3, 1.0)
    m *= np.exp(-t / 0.9) * (1 - np.exp(-t / 0.0015))
    hit = bp(noise(len(t)), 900, 7000) * np.exp(-t / 0.012) * 0.8
    thump = np.sin(osc_phase(48 + 70 * np.exp(-t / 0.05))) * np.exp(-t / 0.22)
    hiss = bp(noise(len(t)), 3000, 12000) * np.exp(-((t - 0.25) / 0.25) ** 2) * 0.10
    place(m * 0.10 * size + hit * 0.5 * size, t0, pan=pan, width=0.5, hall=0.35, cath=0.25)
    place(thump * 0.9 * size + hiss, t0, pan=0.0, hall=0.15)


def servo(t0, dur, f0, f1, gain=0.08, pan=0.0):
    """Rotation motor: bright buzzy tone gliding and settling, band-limited."""
    t = tvec(dur)
    tt = t / dur
    shape = np.sin(np.pi * np.clip(tt * 1.05, 0, 1)) ** 0.7
    f = f0 + (f1 - f0) * shape
    x = additive_saw(f, nharm=30, bright=1.5, fmax=5000) + 0.5 * additive_saw(f * 1.5, nharm=12)
    x *= 1 + 0.25 * np.sin(2 * np.pi * 23 * t)
    x = sweep_filter(x, 600 + 2500 * shape, "lowpass", q=1.5)
    env = shape * (1 - np.exp(-t / 0.05))
    place(x * env * gain, t0, pan=pan, width=0.4, hall=0.3)


def pulse(t0, gain=0.6, f=52.0, click_gain=0.08):
    t = tvec(0.6)
    x = np.sin(osc_phase(f + 45 * np.exp(-t / 0.035))) * np.exp(-t / 0.14) * (1 - np.exp(-t / 0.004))
    click = hp(noise(len(t)), 4000) * np.exp(-t / 0.004) * click_gain
    place(softclip(x * 1.3) * gain + click, t0, hall=0.08)


def tick(t0, gain=0.05, pan=0.0, f=5200):
    t = tvec(0.15)
    x = np.sin(2 * np.pi * f * t) * np.exp(-t / 0.012) + bp(noise(len(t)), 6000, 14000) * np.exp(-t / 0.004) * 0.5
    place(x * gain, t0, pan=pan, hall=0.2)


def crackle(t0, dur, density=40, gain=0.08, pan0=0.0, pan1=0.0):
    """electric sparks: sparse filtered impulses with a density envelope"""
    n = s2i(dur)
    x = np.zeros(n)
    tt = np.arange(n) / n
    prob = density / SR * np.sin(np.pi * tt) ** 0.5
    hits = RNG.random(n) < prob
    x[hits] = RNG.uniform(-1, 1, hits.sum())
    x = bp(x, 1800, 11000, 2)
    # short resonant ring per spark
    x = signal.lfilter([1], [1, -1.6 * np.cos(2 * np.pi * 3200 / SR), 0.81], x) * 0.25 + x
    pans = pan0 + (pan1 - pan0) * tt
    gl, gr = pan_gains(pans)
    place(np.vstack([x * gl, x * gr]) * gain, t0, hall=0.3)


def pad(notes, t0, t1, gain=0.05, attack=2.0, release=2.0, cutoff=(400, 2500), bend=None, voices=3,
        detune=0.08, hall=0.4, cath=0.3):
    """Detuned additive-saw pad with a moving low-pass. bend(t)->semitones."""
    dur = t1 - t0 + release
    t = tvec(dur)
    tt = np.clip(t / max(t1 - t0, 1e-3), 0, 1)
    env = np.clip(t / attack, 0, 1) ** 1.5 * np.clip((t1 + release - t0 - t) / release, 0, 1)
    out = np.zeros((2, len(t)))
    for ni, n in enumerate(notes):
        f0 = 440.0 * 2 ** ((n - 69) / 12.0)
        for v in range(voices):
            dt = (v - (voices - 1) / 2) * detune
            semis = dt + (bend(t + t0) if bend is not None else 0.0)
            f = f0 * 2 ** (semis / 12.0) * (1 + 0.0015 * np.sin(2 * np.pi * (0.13 + 0.07 * v) * t + v))
            x = additive_saw(f, nharm=40, bright=1.0, fmax=4500)
            p = ((v + ni) % voices) / max(voices - 1, 1) * 1.4 - 0.7
            gl, gr = pan_gains(p)
            out[0] += x * gl
            out[1] += x * gr
    fc = cutoff[0] + (cutoff[1] - cutoff[0]) * np.sin(np.pi * 0.5 * tt) ** 2
    for ch in range(2):
        out[ch] = sweep_filter(out[ch], fc, "lowpass", q=0.9)
    out *= env * gain / np.sqrt(len(notes) * voices)
    place(out, t0, hall=hall, cath=cath)


def tone(t0, dur, freq, gain=0.05, attack=0.5, release=1.0, pan=0.0, partials=(1.0,), hall=0.4, cath=0.3,
         vibrato=0.0, bend=None):
    t = tvec(dur)
    f = freq * np.ones_like(t)
    if bend is not None:
        f = f * 2 ** (bend(t + t0) / 12.0)
    f = f * (1 + vibrato * np.sin(2 * np.pi * 5.1 * t))
    ph = osc_phase(f)
    x = np.zeros_like(t)
    for i, a in enumerate(partials):
        x += a * np.sin((i + 1) * ph)
    env = np.clip(t / attack, 0, 1) * np.clip((dur - t) / release, 0, 1)
    place(x * env * gain, t0, pan=pan, width=0.6, hall=hall, cath=cath)


def glass(t0, freq, gain=0.06, pan=0.0, dur=4.0):
    """FM bell / glass chime."""
    t = tvec(dur)
    idx = 2.2 * np.exp(-t / 0.35)
    mod = np.sin(2 * np.pi * freq * 3.5 * t) * idx
    x = np.sin(2 * np.pi * freq * t + mod) * np.exp(-t / 1.4)
    x += 0.35 * np.sin(2 * np.pi * freq * 2.0 * t) * np.exp(-t / 0.6)
    x *= 1 - np.exp(-t / 0.003)
    place(x * gain, t0, pan=pan, width=0.7, hall=0.6, cath=0.6)


def shepard(t0, t1, gain=0.05, octaves_per_s=0.42, base=55.0):
    """Endless rise: octave-spaced sines under a fixed spectral bell."""
    dur = t1 - t0
    t = tvec(dur)
    out = np.zeros(len(t))
    nvo = 7
    for k in range(nvo):
        pos = (k + t * octaves_per_s) % nvo           # position in octaves
        f = base * 2 ** pos
        amp = np.exp(-((pos - nvo / 2) / (nvo / 5.0)) ** 2)
        # avoid phase jumps when wrapping: integrate a continuous frequency
        ph = 2 * np.pi * np.cumsum(f) / SR
        out += np.sin(ph) * amp
    # wraps create clicks: smooth amplitude near wrap points already ~0
    env = np.clip(t / 1.0, 0, 1) ** 2 * np.clip((dur - t) / 0.02, 0, 1)
    rise = (t / dur) ** 2
    place(out * env * gain * (0.4 + 0.6 * rise), t0, width=0.7, hall=0.3)


def roar(t0, t1, gain=0.35):
    """Accretion disk: deep turbulent roar with drifting resonances."""
    dur = t1 - t0
    t = tvec(dur)
    tt = t / dur
    x = noise(len(t), "brown") * 0.8 + noise(len(t), "pink") * 0.25
    y = lp(x, 900, 2)
    for i, (f0, f1) in enumerate([(70, 140), (160, 420), (380, 900)]):
        fc = f0 + (f1 - f0) * (tt ** 1.5) * (1 + 0.1 * np.sin(2 * np.pi * (0.3 + 0.2 * i) * t))
        y += sweep_filter(x, fc, "bandpass", q=3.0) * (0.8 - 0.2 * i)
    am = 1 + 0.25 * np.sin(2 * np.pi * (1.5 + 6.0 * tt ** 2) * t)
    sub = np.sin(osc_phase(36 + 6 * tt)) * 0.6 + np.sin(osc_phase(36.6 + 6 * tt)) * 0.4
    env = np.clip(t / 0.08, 0, 1) * (0.7 + 0.5 * tt ** 2)
    st = np.vstack([y, np.roll(y, 300)]) * am * env
    st += np.vstack([sub, sub]) * env * 0.5
    place(st * gain, t0, hall=0.25, cath=0.1)


def suction(t_end, dur=0.6, gain=0.5):
    """Implosion: everything is sucked into the point (reverse, rising, cut)."""
    t = tvec(dur)
    tt = t / dur
    f = 150 * (9000 / 150) ** (tt ** 2.2)
    y = sweep_filter(noise(len(t), "pink"), f, "bandpass", q=1.5)
    tonal = np.sin(osc_phase(80 * 2 ** (tt * 5.5))) * 0.25
    e = tt ** 2.5
    place((y + tonal) * e * gain, t_end - dur, width=0.8, hall=0.1)


# ============================================================== SCORE =====
def score():
    B = TL.BEAT
    # ---------------------------------------------------------- ACT I --
    # the void: sub air + faint room tone
    t = tvec(TL.T_EMERGE)
    air = lp(noise(len(t), "brown"), 120) * 0.25 + lp(noise(len(t), "pink"), 2500) * 0.012
    air *= np.clip(t / 2.0, 0, 1)
    place(air, 0.0, width=0.9, hall=0.2)
    tone(0.2, TL.T_EMERGE - 0.15, 41.2, gain=0.20, attack=2.5, release=0.3, partials=(1.0, 0.25, 0.08), hall=0.1, cath=0.0)
    # the seam ignites: glassy rising tone + electric crackle travelling
    tone(0.9, 3.7, 1318.5, gain=0.014, attack=1.6, release=0.6, partials=(1.0, 0.3), vibrato=0.002,
         bend=lambda x: -5 + 5 * np.clip((x - 0.9) / 3.0, 0, 1), pan=0.3)
    tone(1.1, 3.5, 659.3, gain=0.012, attack=1.8, release=0.5, partials=(1.0, 0.5, 0.2), pan=-0.3,
         bend=lambda x: -2 + 2 * np.clip((x - 1.1) / 3.0, 0, 1))
    crackle(1.3, 3.1, density=55, gain=0.05, pan0=0.6, pan1=-0.5)
    whoosh(0.5, 3.6, f0=180, f1=1400, gain=0.12, pan0=0.7, pan1=-0.6)
    reverse_swell(TL.T_EMERGE, 1.6, lo=120, hi=5000, gain=0.42)

    # ---------------------------------------------------------- ACT II -
    boom(TL.T_EMERGE, size=1.0, pitch=1.0)
    # the structure rises out of the liquid: deep groan + water
    t = tvec(6.0)
    groan = sweep_filter(noise(len(t), "brown"), 60 + 140 * (t / 6.0), "bandpass", q=4.0)
    place(groan * np.sin(np.pi * np.clip(t / 6.0, 0, 1)) * 0.45, TL.T_EMERGE + 0.2, width=0.6, hall=0.3, cath=0.3)
    t = tvec(6.0)
    water = bp(noise(len(t), "pink"), 150, 1600) * (0.5 + 0.5 * np.sin(2 * np.pi * 0.35 * t) ** 2) * 0.03
    place(water * np.clip(t / 1.0, 0, 1) * np.clip((6.0 - t) / 0.5, 0, 1), TL.T_EMERGE, width=0.9, hall=0.3)
    # each ring ignites and adds one note to the chord (outer -> inner)
    chord = [38, 45, 50, 52, 57]  # D2 A2 D3 E3 A3
    for k, ti in enumerate(TL.IGNITES):
        f = 440.0 * 2 ** ((chord[k] - 69) / 12.0)
        pulse(ti, gain=0.30, f=44.0)
        glass(ti, f * 4, gain=0.018, pan=(-0.6 + 0.3 * k))
        tone(ti, TL.T_DISTORT - ti + 1.5, f, gain=0.035, attack=0.25, release=1.5,
             partials=(1.0, 0.45, 0.22, 0.1, 0.06), pan=(-0.5 + 0.25 * k), hall=0.4, cath=0.4,
             bend=lambda x: 0.0)
    pad([38, 45, 52, 57], TL.T_EMERGE + 0.5, TL.T_DISTORT, gain=0.06, attack=3.0, release=1.2,
        cutoff=(250, 1800))
    reverse_swell(TL.T_ANATOMY, 1.2, lo=200, hi=4000, gain=0.32)

    # --------------------------------------------------------- ACT III -
    boom(TL.T_ANATOMY, size=0.55, pitch=1.15, metal=False)
    clank(TL.T_ANATOMY, size=0.9, seed=9)
    # pneumatic release
    t = tvec(1.2)
    place(bp(noise(len(t)), 2500, 11000) * np.exp(-t / 0.35) * 0.06, TL.T_ANATOMY + 0.05, width=0.9, hall=0.3)
    # heartbeat pulse on every beat + off-beat ticks
    for k in range(8):
        tb = TL.T_ANATOMY + k * B
        pulse(tb, gain=0.42 if k % 2 == 0 else 0.30)
        tick(tb + B / 2, gain=0.035, pan=0.5 if k % 2 else -0.5)
    # three mechanical moves, each locking on a beat
    for i, tl in enumerate(TL.LOCKS):
        servo(tl - 1.25, 1.3, 90 + 25 * i, 260 + 60 * i, gain=0.05, pan=(-0.4 + 0.4 * i))
        whoosh(tl - 1.1, 1.15, f0=200, f1=2200, gain=0.10, pan0=(0.6 - 0.6 * i), pan1=(-0.4 + 0.5 * i))
        clank(tl, size=1.0 + 0.15 * i, pan=(-0.3 + 0.3 * i), seed=i)
    # spin-up towards act IV
    t = tvec(TL.T_DISTORT - TL.LOCKS[2])
    tt = t / t[-1]
    f = 70 * 2 ** (2.2 * tt ** 1.6)
    whir = additive_saw(f, nharm=20, fmax=4000) * (0.5 + 0.5 * np.sin(2 * np.pi * (2 + 14 * tt ** 2) * t))
    whir = sweep_filter(whir, 400 + 3000 * tt, "lowpass", q=2.0) * tt ** 1.5 * 0.07
    place(whir, TL.LOCKS[2], width=0.6, hall=0.3)
    pad([38, 45, 53], TL.T_ANATOMY, TL.T_DISTORT, gain=0.04, attack=2.0, release=0.8, cutoff=(300, 1200))
    reverse_swell(TL.T_DISTORT, 1.5, lo=100, hi=7000, gain=0.5)

    # ---------------------------------------------------------- ACT IV -
    boom(TL.T_DISTORT, size=0.9, pitch=0.85)
    # gravity drags every pitch down (redshift)
    redshift = lambda x: -7.0 * np.clip((x - TL.T_DISTORT) / (TL.T_COLLAPSE - TL.T_DISTORT), 0, 1) ** 1.3
    pad([38, 45, 50, 53, 57], TL.T_DISTORT, TL.T_COLLAPSE, gain=0.075, attack=0.8, release=0.25,
        cutoff=(1600, 400), bend=redshift, cath=0.5)
    tone(TL.T_DISTORT, 6.0, 27.5, gain=0.22, attack=1.5, release=0.1, partials=(1.0, 0.5, 0.2), hall=0.0, cath=0.0)
    # the spinning rings: Doppler whooshes accelerating
    tw = TL.T_DISTORT + 0.6
    k = 0
    while tw < TL.T_COLLAPSE - 0.3:
        d = max(0.95 - 0.13 * k, 0.28)
        whoosh(tw, d * 1.1, f0=150, f1=1800 + 150 * k, gain=0.07 + 0.012 * k, pan0=(-0.8 if k % 2 else 0.8),
               pan1=(0.8 if k % 2 else -0.8))
        tw += d
        k += 1
    # pulse continues, faster
    for k in range(16):
        tb = TL.T_DISTORT + k * B / 2
        pulse(tb, gain=0.34 if k % 2 == 0 else 0.18, f=48)
    # vortex wind
    t = tvec(6.0)
    tt = t / 6.0
    wind = sweep_filter(noise(len(t), "pink"), 200 + 2500 * tt ** 2, "bandpass", q=1.2) * tt ** 1.4 * 0.22
    place(np.vstack([wind, np.roll(wind, 900)]), TL.T_DISTORT, hall=0.3)
    shepard(TL.T_DISTORT + 2.0, TL.T_COLLAPSE, gain=0.035, octaves_per_s=0.35, base=40)
    crackle(TL.T_COLLAPSE - 2.0, 2.0, density=220, gain=0.08, pan0=-0.6, pan1=0.6)
    reverse_swell(TL.T_COLLAPSE, 1.3, lo=150, hi=9000, gain=0.55)

    # ----------------------------------------------------------- ACT V -
    boom(TL.T_COLLAPSE, size=1.25, pitch=0.8)
    roar(TL.T_COLLAPSE, TL.T_BREATH, gain=0.30)
    pad([38, 45, 50, 53, 60], TL.T_COLLAPSE, TL.T_BREATH, gain=0.06, attack=1.0, release=0.02,
        cutoff=(500, 3500), cath=0.4)
    shepard(TL.T_COLLAPSE + 1.0, TL.T_BREATH, gain=0.06, octaves_per_s=0.55, base=50)
    # ticking accelerates (8ths -> 16ths)
    tb = TL.T_COLLAPSE
    while tb < TL.T_BREATH - 0.05:
        sub = B / 2 if tb < TL.T_COLLAPSE + 3.0 else B / 4
        tick(tb, gain=0.03 + 0.03 * (tb - TL.T_COLLAPSE) / 6.0, pan=RNG.uniform(-0.6, 0.6), f=4200)
        tb += sub
    for k in range(8):
        pulse(TL.T_COLLAPSE + k * B, gain=0.4, f=46)
    suction(TL.T_BREATH, dur=0.95, gain=0.55)

    # ------------------------------------------------- BREATH (silence) -
    _POST[0] = True
    tone(TL.T_BREATH + 0.08, TL.T_IMPACT - TL.T_BREATH - 0.1, 4186.0, gain=0.004, attack=0.25, release=0.2,
         hall=0.2, cath=0.0)
    # a single low heartbeat in the void
    pulse(TL.T_BREATH + 0.18, gain=0.10, f=40, click_gain=0.0)
    reverse_swell(TL.T_IMPACT, 0.42, lo=300, hi=12000, gain=0.35)
    _POST[0] = False

    # ---------------------------------------------------------- ACT VI -
    boom(TL.T_IMPACT, size=1.6, pitch=0.72)
    boom(TL.T_IMPACT + 0.012, size=0.6, pitch=1.6, metal=False, pan=0.0)
    whoosh(TL.T_IMPACT, 1.6, f0=4000, f1=300, gain=0.22, pan0=-0.2, pan1=0.2)
    # resolution: D major add9, bright and wide
    pad([38, 45, 54, 57, 64], TL.T_IMPACT + 0.05, TL.T_END - 0.9, gain=0.07, attack=1.2, release=0.9,
        cutoff=(3200, 1200), cath=0.8, hall=0.5)
    tone(TL.T_IMPACT + 0.2, TL.T_END - TL.T_IMPACT - 0.5, 73.42, gain=0.07, attack=0.8, release=1.6,
         partials=(1.0, 0.3, 0.1), hall=0.2, cath=0.3)
    # the halo hum
    tone(TL.T_IMPACT + 0.6, 5.5, 587.33, gain=0.008, attack=1.2, release=1.2, partials=(1.0, 0.2), pan=-0.3, vibrato=0.001)
    tone(TL.T_IMPACT + 0.7, 5.4, 880.0, gain=0.006, attack=1.2, release=1.2, partials=(1.0,), pan=0.3, vibrato=0.0012)
    # title condenses letter by letter (centre out): a cascade of glass chimes
    notes = [69, 74, 76, 78, 81, 86]  # A4 D5 E5 F#5 A5 D6
    for k in range(6):
        tk = TL.T_TITLE + k * 0.075
        glass(tk, 440.0 * 2 ** ((notes[k] - 69) / 12.0), gain=0.030 - 0.002 * k,
              pan=(0.0 if k == 0 else (0.15 * k if k % 2 else -0.15 * k)))
    # light sweep across the word
    whoosh(TL.T_TITLE + 1.9, 1.4, f0=2500, f1=9000, gain=0.035, pan0=-0.7, pan1=0.7)
    glass(TL.T_TITLE + 2.55, 1760.0, gain=0.010, pan=0.3)
    # everything converges back to the point
    t = tvec(1.0)
    tt = t / 1.0
    conv = sweep_filter(noise(len(t), "pink"), 8000 * (1 - tt) ** 2 + 300, "bandpass", q=1.5) * np.sin(np.pi * tt) * 0.06
    place(conv, TL.T_FADE + 0.2, width=0.7, hall=0.4)
    glass(TL.T_END - 0.42, 1174.66, gain=0.022, pan=0.0, dur=0.6)


# ============================================================ MASTER ======
def master():
    hall = make_ir(3.0, 2.4, 1.4, predelay=0.018, density_seed=3)
    cath = make_ir(7.0, 6.5, 3.5, predelay=0.045, density_seed=7)
    mix = DRY.copy()
    mix += convolve_bus(HALL, hall) * 0.30
    mix += convolve_bus(CATH, cath) * 0.26
    post = POST_DRY + convolve_bus(POST_HALL, hall) * 0.30
    t = np.arange(N) / SR
    # --- dramatic arc: per-section loudness targets (LUFS) -------------
    import pyloudnorm as pyln
    meter = pyln.Meter(SR)
    sections = [(0.0, TL.T_EMERGE, -27.0), (TL.T_EMERGE, TL.T_ANATOMY, -19.0),
                (TL.T_ANATOMY, TL.T_DISTORT, -18.0), (TL.T_DISTORT, TL.T_COLLAPSE, -16.5),
                (TL.T_COLLAPSE, TL.T_BREATH, -14.5), (TL.T_IMPACT, TL.T_IMPACT + 1.6, -12.5),
                (TL.T_IMPACT + 1.6, TL.T_END - 0.4, -20.5)]
    gcurve = np.ones(N)
    for a, b, target in sections:
        i0, i1 = s2i(a), s2i(b)
        L = meter.integrated_loudness(mix[:, i0:i1].T)
        g = 10 ** ((target - L) / 20.0)
        print(f"  section {a:6.2f}-{b:6.2f}: {L:6.1f} LUFS -> {target} (gain {20 * np.log10(g):+5.1f} dB)")
        gcurve[i0:i1] = g
    # the breath: everything (reverb tails included) collapses to silence
    gcurve[s2i(TL.T_BREATH):s2i(TL.T_IMPACT)] = 10 ** (-60 / 20)
    gcurve[s2i(TL.T_END - 0.4):] = gcurve[s2i(TL.T_END - 0.41)]
    # smooth the gain changes: fast at the cuts, slow inside act VI
    sm = signal.lfilter([1 - 0.9985], [1, -0.9985], gcurve)       # ~14 ms
    slow = signal.lfilter([1 - 0.99996], [1, -0.99996], gcurve)    # ~0.5 s
    w = np.clip((t - (TL.T_IMPACT + 1.0)) / 0.6, 0, 1)
    gcurve = sm * (1 - w) + slow * w
    # the cut into the breath is instantaneous (a real silence)
    gcurve[s2i(TL.T_BREATH):s2i(TL.T_IMPACT)] = 10 ** (-60 / 20)
    mix *= gcurve
    # post elements follow the gain of the final impact section
    mix += post * gcurve[s2i(TL.T_IMPACT + 0.5)]
    # subsonic clean-up and a touch of air
    for ch in range(2):
        mix[ch] = hp(mix[ch], 24, 2)
    # final fade so the reverb tail ends with the picture
    mix *= np.clip((TL.T_END - t) / 0.35, 0, 1) ** 1.5
    mix *= np.clip(t / 0.05, 0, 1)
    # overall loudness normalisation (EBU R128 integrated), then a look-ahead peak limiter
    loud = meter.integrated_loudness(mix.T)
    target = -16.0
    mix *= 10 ** ((target - loud) / 20.0)
    print(f"programme loudness: {loud:.2f} LUFS -> {target}")
    ceiling = 10 ** (-1.2 / 20)
    peak = np.abs(mix).max(axis=0)
    look = int(0.004 * SR)
    need = np.maximum(peak / ceiling, 1.0)
    # running max over the look-ahead window, then smooth release
    from scipy.ndimage import maximum_filter1d
    need = maximum_filter1d(need, size=2 * look + 1)
    g = 1.0 / need
    g = signal.lfilter([0.002], [1, -0.998], g - 1.0) + 1.0
    g = np.minimum(g, 1.0 / maximum_filter1d(np.maximum(peak / ceiling, 1.0), size=2 * look + 1))
    mix *= g
    mix = np.clip(mix, -ceiling, ceiling)
    return mix


def main():
    score()
    mix = master()
    out = os.path.join(ROOT, "audio", "singularity_48k.wav")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    pcm = (np.clip(mix.T, -1, 1) * (2 ** 31 - 1)).astype(np.int32)
    wavfile.write(out, SR, pcm)
    try:
        import pyloudnorm as pyln
        print(f"final loudness: {pyln.Meter(SR).integrated_loudness(mix.T):.2f} LUFS, peak {20 * np.log10(np.abs(mix).max()):.2f} dBFS")
    except Exception:
        pass
    print("wrote", out, mix.shape[1] / SR, "s")


if __name__ == "__main__":
    main()
