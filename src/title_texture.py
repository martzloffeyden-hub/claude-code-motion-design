"""Builds the title texture for the final shot.

The word is set in Inter Display ExtraLight (SIL Open Font License), widely
tracked, and converted to a signed distance field so the shader can blur,
glow, knock out and "condense" the letters at any scale.

Channels (float32):
  R  signed distance to the glyph edge, in cap-height units (negative inside)
  G  letter index (0..N-1) of the nearest letter, as a float
  B  horizontal position inside that letter (0..1)
  A  antialiased coverage
"""
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage

TEXT = "SINGULARITY"
FONT = "/usr/share/fonts/opentype/inter/InterDisplay-ExtraLight.otf"
CAP = 200            # cap height in texture pixels
TRACK = 0.62         # extra spacing between letters, in cap heights
PAD = 1.3            # padding around the word, in cap heights

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(os.path.dirname(HERE), "output", "title_sdf.npy")

# geometry shared with the shader (texture aspect is width / height)
META = {}


def build():
    if os.path.exists(CACHE):
        arr = np.load(CACHE)
        _meta(arr)
        return arr
    # find the font size that gives the wanted cap height
    size = 100
    f = ImageFont.truetype(FONT, size)
    bb = f.getbbox("H")
    cap_px = bb[3] - bb[1]
    size = int(round(size * CAP / cap_px))
    font = ImageFont.truetype(FONT, size)
    hb = font.getbbox("H")
    cap_top = hb[1]

    advs, boxes = [], []
    x = 0.0
    for ch in TEXT:
        b = font.getbbox(ch)
        w = font.getlength(ch)
        boxes.append((x, b))
        advs.append(w)
        x += w + TRACK * CAP
    total = x - TRACK * CAP
    pad = int(PAD * CAP)
    W = int(total) + 2 * pad
    H = CAP + 2 * pad
    W += (-W) % 4

    img = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(img)
    centers = []
    for ch, (x0, b) in zip(TEXT, boxes):
        d.text((pad + x0, pad - cap_top), ch, font=font, fill=255)
        centers.append((pad + x0 + (b[0] + b[2]) / 2.0, pad + x0 + b[0], pad + x0 + b[2]))
    cov = np.asarray(img, dtype=np.float32) / 255.0
    inside = cov >= 0.5
    d_out = ndimage.distance_transform_edt(~inside)
    d_in = ndimage.distance_transform_edt(inside)
    sdf = (d_out - d_in) / CAP

    # nearest letter (by x) and local x inside it
    xs = np.arange(W, dtype=np.float32)
    cx = np.array([c[0] for c in centers], dtype=np.float32)
    idx = np.argmin(np.abs(xs[:, None] - cx[None, :]), axis=1)
    x0s = np.array([c[1] for c in centers], dtype=np.float32)
    x1s = np.array([c[2] for c in centers], dtype=np.float32)
    local = np.clip((xs - x0s[idx]) / np.maximum(x1s[idx] - x0s[idx], 1.0), 0.0, 1.0)

    arr = np.zeros((H, W, 4), dtype=np.float32)
    arr[..., 0] = sdf
    arr[..., 1] = idx[None, :].astype(np.float32)
    arr[..., 2] = local[None, :]
    arr[..., 3] = cov
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    np.save(CACHE, arr)
    _meta(arr)
    return arr


def _meta(arr):
    h, w = arr.shape[:2]
    META.update(width=w, height=h, aspect=w / h, cap_frac=CAP / h, letters=len(TEXT))


if __name__ == "__main__":
    a = build()
    print(a.shape, META)
    prev = (np.clip(a[..., 3], 0, 1) * 255).astype(np.uint8)
    Image.fromarray(prev).save(os.path.join(os.path.dirname(HERE), "output", "title_preview.png"))
