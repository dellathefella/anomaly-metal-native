#!/usr/bin/env python3
"""bandedge.py <screenshot.jpg> [thresh] — measure the right-edge black band.

Scans three rows (2%, 50%, 98% height) for the rightmost pixel brighter than
`thresh` (sum of RGB), prints the edge x per row, the tilt in degrees, and the
band fraction (edge/W). Matches the project's ledger numbers (top~2311,
mid~2297, bot~2287, tilt~0.91 deg, BAND@0.760) on a healthy in-game frame.
"""
import sys
import numpy as np
from PIL import Image

f = sys.argv[1]
thresh = int(sys.argv[2]) if len(sys.argv) > 2 else 15
a = np.asarray(Image.open(f).convert('RGB')).astype(np.int32)
H, W, _ = a.shape
lum = a.sum(2)


def edge(y):
    xs = np.nonzero(lum[y] > thresh)[0]
    return int(xs.max()) if len(xs) else -1


top = edge(int(H * 0.02))
mid = edge(int(H * 0.50))
bot = edge(int(H * 0.98))
tilt = np.degrees(np.arctan((top - bot) / float(H * 0.96))) if top >= 0 and bot >= 0 else 0.0
print('%-28s %dx%d top=%d mid=%d bot=%d tilt=%.2f deg -> BAND@%.3f' %
      (f.split('/')[-1], W, H, top, mid, bot, tilt, mid / float(W)))
