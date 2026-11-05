#!/usr/bin/env python3
"""Convert a raw RGBA16F RT readback (/tmp/rtdump/*.rgba) to PNG.

usage: raw16f2png.py <raw> <w> <h> <out.png>
Half-float decode via numpy float16; tone-maps with a simple clamp.
"""
import sys
import numpy as np
from PIL import Image

raw, w, h, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
a = np.fromfile(raw, dtype=np.float16).reshape(h, w, 4).astype(np.float32)
rgb = np.clip(a[:, :, :3], 0.0, 1.0)
img = (rgb * 255.0).astype(np.uint8)
Image.fromarray(img).save(out)
print(f"{out}: {w}x{h} mean={rgb.mean():.4f} max={rgb.max():.4f}")
