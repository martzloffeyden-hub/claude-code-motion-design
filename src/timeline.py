"""SINGULARITY — master timeline.

Single source of truth shared by the picture (injected into the GLSL as
#defines) and the sound design, so every cut, hit and swell lands on the
same frame in both.

Tempo: 80 BPM -> one beat = 0.75 s, one bar (4 beats) = 3 s.
Every act lasts exactly 8 beats (6 s), except the breath before the
final impact (1 beat) and the coda.
"""

FPS = 60
WIDTH = 1920
HEIGHT = 1080
BPM = 80.0
BEAT = 60.0 / BPM  # 0.75 s

DURATION = 36.0
TOTAL_FRAMES = int(round(DURATION * FPS))  # 2160

# --- Acts -------------------------------------------------------------------
T_VOID = 0.0         # I    macro: a seam of light ignites along a machined edge
T_EMERGE = 4.5       # II   wide: the structure revealed over a black mirror
T_ANATOMY = 10.5     # III  the rings unlock and start their gimbal choreography
T_DISTORT = 16.5     # IV   a singularity is born at the core, space bends
T_COLLAPSE = 22.5    # V    the rings are torn into an accretion disk
T_BREATH = 28.5      # --   implosion, one beat of silence
T_IMPACT = 29.25     # VI   shockwave, letterbox opens, the last ring, title
T_TITLE = 30.375     # title starts resolving
T_FADE = 34.8        # final fade begins
T_END = DURATION

SHOTS = [
    # (name, shader, start, end)
    ("void", "world", T_VOID, T_EMERGE),
    ("emerge", "world", T_EMERGE, T_ANATOMY),
    ("anatomy", "world", T_ANATOMY, T_DISTORT),
    ("distort", "world", T_DISTORT, T_COLLAPSE),
    ("collapse", "blackhole", T_COLLAPSE, T_IMPACT),
    ("final", "final", T_IMPACT, T_END),
]

# Mechanical locks of the rings during act III (on every second beat).
LOCKS = [T_ANATOMY + BEAT * k for k in (2, 4, 6)]  # 12.0, 13.5, 15.0
# Seams igniting ring by ring during act II (one per beat, inner -> outer).
IGNITES = [T_EMERGE + BEAT * (1 + k) for k in range(5)]

# Letterbox: 2.39:1 until the impact, then opens to full 16:9.
LETTERBOX_ASPECT = 2.39
LETTERBOX_OPEN_START = T_IMPACT
LETTERBOX_OPEN_DUR = 1.1


def glsl_defines():
    d = {
        "T_VOID": T_VOID, "T_EMERGE": T_EMERGE, "T_ANATOMY": T_ANATOMY,
        "T_DISTORT": T_DISTORT, "T_COLLAPSE": T_COLLAPSE, "T_BREATH": T_BREATH,
        "T_IMPACT": T_IMPACT, "T_TITLE": T_TITLE, "T_FADE": T_FADE,
        "T_END": T_END, "BEAT": BEAT,
    }
    for i, t in enumerate(LOCKS):
        d[f"T_LOCK{i}"] = t
    for i, t in enumerate(IGNITES):
        d[f"T_IGN{i}"] = t
    return "\n".join(f"#define {k} {float(v):.6f}" for k, v in d.items()) + "\n"


def letterbox_bar(t, height=HEIGHT, width=WIDTH):
    """Height in pixels of each black bar at time t."""
    full = (height - width / LETTERBOX_ASPECT) / 2.0
    if t < LETTERBOX_OPEN_START:
        return full
    x = min(1.0, (t - LETTERBOX_OPEN_START) / LETTERBOX_OPEN_DUR)
    # ease-out quint: snaps open with the shockwave, settles softly
    e = 1.0 - (1.0 - x) ** 5
    return full * (1.0 - e)
