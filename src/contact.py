#!/usr/bin/env python3
"""Assemble PNG stills into a labelled contact sheet."""
import sys
from PIL import Image, ImageDraw, ImageFont
files = sys.argv[2:]
out = sys.argv[1]
ims = [Image.open(f).convert("RGB") for f in files]
w, h = ims[0].size
cols = 2 if len(ims) > 1 else 1
rows = (len(ims) + cols - 1) // cols
sheet = Image.new("RGB", (w * cols, h * rows), (40, 40, 40))
d = ImageDraw.Draw(sheet)
for i, (im, f) in enumerate(zip(ims, files)):
    x, y = (i % cols) * w, (i // cols) * h
    sheet.paste(im, (x, y))
    d.text((x + 6, y + 4), f.split("/")[-1], fill=(255, 80, 80))
sheet.save(out)
