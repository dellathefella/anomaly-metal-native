#!/usr/bin/env python3
"""p4 t5: visual regression diff + contact sheet (docs/VISUAL_HARNESS.md).

usage:
  harness/diff.py --renderer gl                  # compare captures vs goldens
  harness/diff.py --renderer gl --set-goldens    # accept current captures
  harness/diff.py --renderer gl --goldens gl --psnr 25   # Metal parity pass

Compares harness/captures/<renderer>/*.jpg against
harness/goldens/<goldens>/*.jpg: per-pixel max delta, PSNR, heatmap overlay
for failures, and a contact sheet at harness/reports/<ts>/contact.png.
Cases listed in known_gaps.txt are downgraded to "warn". Exit code 1 if any
case fails.
"""
import argparse
import datetime
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent


def load_known_gaps():
    gaps = {}
    p = HERE / "known_gaps.txt"
    if p.exists():
        for line in p.read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            tok, _, note = line.partition(" ")
            gaps[tok] = note.strip()
    return gaps


def compare(golden: Path, capture: Path, psnr_min: float):
    a = np.asarray(Image.open(golden).convert("RGB"), dtype=np.int16)
    b = np.asarray(Image.open(capture).convert("RGB"), dtype=np.int16)
    if a.shape != b.shape:
        return None, f"size mismatch {a.shape[1]}x{a.shape[0]} vs {b.shape[1]}x{b.shape[0]}", None
    d = np.abs(a - b)
    max_delta = int(d.max())
    mse = float(np.mean(d.astype(np.float64) ** 2))
    psnr = float("inf") if mse == 0 else 10.0 * math.log10(255.0 * 255.0 / mse)
    ok = (mse == 0) or (psnr >= psnr_min)
    status = "pass" if ok else "fail"
    detail = f"maxΔ={max_delta} PSNR={'inf' if mse == 0 else f'{psnr:.1f}'}"
    heat = None
    if not ok or max_delta > 24:  # always visualize drift beyond noise
        m = d.max(axis=2)
        heat = np.zeros(a.shape[:2], dtype=np.uint8)
        heat[m > 8] = 64
        heat[m > 24] = 160
        heat[m > 64] = 255
    return status, detail, heat


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--renderer", default="gl", help="captures bucket (gl|metal)")
    ap.add_argument("--goldens", default=None, help="goldens bucket (default: renderer)")
    ap.add_argument("--psnr", type=float, default=40.0, help="min PSNR for pass (bit-exact within a renderer ⇒ high; use ~25 for cross-renderer parity)")
    ap.add_argument("--set-goldens", action="store_true", help="copy captures into goldens and exit")
    args = ap.parse_args()

    captures = HERE / "captures" / args.renderer
    goldens_dir = HERE / "goldens" / (args.goldens or args.renderer)
    if not captures.is_dir():
        sys.exit(f"no captures for renderer '{args.renderer}' ({captures})")

    shots = sorted(captures.glob("*.jpg"))
    if not shots:
        sys.exit(f"no captures found in {captures}")

    if args.set_goldens:
        goldens_dir.mkdir(parents=True, exist_ok=True)
        for s in shots:
            (goldens_dir / s.name).write_bytes(s.read_bytes())
            print(f"golden: {s.name}")
        return 0

    gaps = load_known_gaps()
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    report = HERE / "reports" / ts
    report.mkdir(parents=True, exist_ok=True)

    results, tiles = [], []
    any_fail = False
    for s in shots:
        case = s.stem
        golden = goldens_dir / s.name
        if not golden.exists():
            results.append((case, "new", "no golden — run --set-goldens"))
            continue
        status, detail, heat = compare(golden, s, args.psnr)
        if status is None:
            results.append((case, "fail", detail))
            any_fail = True
            continue
        if status == "fail" and case in gaps:
            status, detail = "warn", detail + f" (known gap: {gaps[case]})"
        if status == "fail":
            any_fail = True
        results.append((case, status, detail))
        if heat is not None:
            hp = report / f"{case}.heat.png"
            Image.fromarray(heat).save(hp)

    # contact sheet: golden | capture | heat side-by-side per case
    tw, th = 320, 180
    cols = 3
    rows = max(1, len(results))
    sheet = Image.new("RGB", (tw * cols + 8, th * rows + 24 * rows + 8), (24, 24, 24))
    draw = ImageDraw.Draw(sheet)
    y = 8
    for case, status, detail in results:
        for c, path in enumerate((goldens_dir / f"{case}.jpg", captures / f"{case}.jpg", report / f"{case}.heat.png")):
            if path.exists():
                t = Image.open(path).convert("RGB").resize((tw, th))
                sheet.paste(t, (8 + c * (tw + 0), y + 20))
        color = {"pass": (0, 200, 0), "warn": (220, 180, 0), "fail": (230, 60, 60), "new": (120, 120, 250)}.get(status, (200, 200, 200))
        draw.text((8, y), f"{case}: {status} — {detail}", fill=color)
        y += th + 24
    sheet.save(report / "contact.png")

    for case, status, detail in results:
        print(f"{status.upper():5} {case:32} {detail}")
    print(f"\nreport: {report/'contact.png'}")
    return 1 if any_fail else 0


if __name__ == "__main__":
    sys.exit(main())
