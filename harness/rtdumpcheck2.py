#!/usr/bin/env python3
"""Analyze /tmp/rtdump/*.rgba raw dumps: per-RT coverage, esp. the band region x>2300.

Prints per RT: size/bpp, coverage % in the band (x 2400..3000) and left (x 24..624),
and min..max lit-x at five rows (reveals parallelogram vs straight-edge shapes).
Handles any RT height (the drawable size varies: 1676/1680/1684) and 4/8-byte px.
"""
import os, glob
import numpy as np

W = 3024
for f in sorted(glob.glob('/tmp/rtdump/*.rgba')):
    sz = os.path.getsize(f)
    name = os.path.basename(f)[:-5]
    H = bpp = None
    for b in (4, 8):
        if sz % (W * b) == 0:
            h = sz // (W * b)
            if 1600 <= h <= 1700:
                H, bpp = h, b
                break
    if H is None:
        print('%-22s size %d (unexpected, skip)' % (name, sz))
        continue
    dt = np.uint8 if bpp == 4 else np.uint16
    a = np.fromfile(f, dtype=dt).reshape(H, W, 4)
    if bpp == 4:
        nz = (a[:, :, :3].astype(np.uint16).sum(axis=2) > 24)
    else:
        nz = (a[:, :, :3] != 0).any(axis=2)
    edges = []
    for fy in (0.02, 0.25, 0.5, 0.75, 0.98):
        y = int(H * fy)
        xs = np.nonzero(nz[y])[0]
        edges.append('y%d:%d..%d' % (y, xs.min() if len(xs) else -1, xs.max() if len(xs) else -1))
    band = nz[:, 2400:3000].mean() * 100
    left = nz[:, 24:624].mean() * 100
    print('%-24s %dx%d bpp%d band%%=%5.1f left%%=%5.1f edges(min..max) %s' %
          (name, W, H, bpp, band, left, ' '.join(edges)))
