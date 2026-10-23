#!/usr/bin/env python3
"""Fit the Color Mixer (HSL) to Lightroom.

Usage:
  python3 fit_hsl.py <kit folder> <output .swift file>

Model (measured, Oct 2026): every band moves hue, chroma and lightness (Oklab) by an amount
that depends on the pixel's Oklab hue and chroma. For each exported file (four alternate
bands at ±50, see make_kit.py batch 4) we measure the change as tables over
72 hues × 7 chroma rows, then cut each group table into its four bands at the hues where
the other group's bands sit. Values in between scale linearly (value / 50).
Writes HSLModelData.swift (tables as base64 Float32).
"""
import base64
import re
import sys
from pathlib import Path

import numpy as np
from scipy.ndimage import gaussian_filter1d

sys.path.insert(0, str(Path(__file__).parent))
import compare  # noqa: E402

BANDS = ["Red", "Orange", "Yellow", "Green", "Aqua", "Purple", "Magenta", "Blue"]
ORDER = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]  # app order
GROUPS = {"a": ["Red", "Yellow", "Aqua", "Purple"], "b": ["Orange", "Green", "Blue", "Magenta"]}
PARTS = {"hue": 0, "sat": 1, "lightn": 2}
HB = 72                                                   # 5° hue bins
CHROMA = np.array([0.0, 0.02, 0.04, 0.07, 0.10, 0.14, 0.20, 0.30])  # row edges
PATTERN = re.compile(r"cal_\d\d_(hue|sat|lightn)(a|b)_([mp])(\d+)")


def downsample(a, f=4):
    h, w = a.shape[:2]
    return a[:h // f * f, :w // f * f].reshape(h // f, f, w // f, f, -1).mean((1, 3))


def lch(img):
    o = compare.oklab(img)
    return o[..., 0], np.hypot(o[..., 1], o[..., 2]), np.degrees(np.arctan2(o[..., 2], o[..., 1])) % 360


def measure(base, out):
    """3 × rows × 72 table: hue shift (°), ln chroma ratio, ln lightness ratio."""
    L0, C0, H0 = lch(base)
    L1, C1, H1 = lch(out)
    values = [((H1 - H0 + 180) % 360) - 180,
              np.log(np.maximum(C1, 1e-4) / np.maximum(C0, 1e-4)),
              np.log(np.maximum(L1, 1e-4) / np.maximum(L0, 1e-4))]
    usable = L0 > 0.08
    hi = np.clip((H0 / 5).astype(int), 0, HB - 1)
    ci = np.clip(np.searchsorted(CHROMA, C0) - 1, 0, len(CHROMA) - 2)
    rows = len(CHROMA) - 1
    t = np.full((3, rows, HB), np.nan)
    for c in range(rows):
        for i in range(HB):
            sel = usable & (hi == i) & (ci == c)
            if sel.sum() > 15:
                for a in range(3):
                    t[a, c, i] = np.median(values[a][sel])
    xs = np.arange(HB)
    for a in range(3):
        for c in range(rows):
            ok = ~np.isnan(t[a, c])
            if ok.sum() >= 3:
                t[a, c] = np.interp(xs, np.concatenate([xs[ok] - HB, xs[ok], xs[ok] + HB]), np.tile(t[a, c][ok], 3))
                t[a, c] = gaussian_filter1d(t[a, c], 0.8, mode="wrap")
        for c in range(rows):
            if np.isnan(t[a, c]).all():
                filled = [d for d in range(rows) if not np.isnan(t[a, d]).all()]
                t[a, c] = t[a, min(filled, key=lambda d: abs(d - c))]
        t[a, 0] = 0  # greys stay grey
    return t


def centres(tables):
    """Band centre hues: where the *other* group's hue table is ~0 between its peaks."""
    out = {}
    for group, other in (("a", "b"), ("b", "a")):
        # hue response of the other group (+50), summed over chroma rows
        resp = np.abs(tables[("hue", other, 1)][0]).sum(0)
        resp = gaussian_filter1d(resp, 1.0, mode="wrap")
        # local minima = this group's band centres (4 of them), largest separation first
        minima = [i for i in range(HB) if resp[i] <= resp[i - 1] and resp[i] <= resp[(i + 1) % HB]]
        minima = sorted(minima, key=lambda i: resp[i])[:4]
        hues = sorted(m * 5 + 2.5 for m in minima)
        # assign by order around the circle, starting from the one nearest red (≈ 20°) etc.
        expected = {"Red": 20, "Yellow": 95, "Aqua": 185, "Purple": 315,
                    "Orange": 50, "Green": 140, "Blue": 255, "Magenta": 350}
        for band in GROUPS[group]:
            out[band] = min(hues, key=lambda h: abs(((h - expected[band] + 180) % 360) - 180))
    return out


def window(band, centre, all_centres):
    """1 between the two neighbouring other-group centres, 0 outside (5° bins)."""
    other = [all_centres[b] for g, bands in GROUPS.items() if band not in bands for b in bands]
    lo = max(((centre - h) % 360 for h in other), default=180)
    lo = min(((centre - h) % 360 for h in other))
    hi = min(((h - centre) % 360 for h in other))
    hues = np.arange(HB) * 5 + 2.5
    d = ((hues - centre + 180) % 360) - 180
    return ((d >= -lo) & (d <= hi)).astype(float)


def main():
    kit, target = Path(sys.argv[1]).expanduser(), Path(sys.argv[2]).expanduser()
    files = compare.index(kit / "adobe")
    base = downsample(compare.load(files["cal_00_base"]))
    tables = {}
    for key, path in files.items():
        m = PATTERN.search(key)
        if m:
            part, group, sign, _ = m.groups()
            tables[(part, group, 1 if sign == "p" else 0)] = measure(base, downsample(compare.load(path)))
    missing = [(p, g, s) for p in PARTS for g in GROUPS for s in (0, 1) if (p, g, s) not in tables]
    if missing:
        sys.exit(f"✗ Missing exports: {missing}")
    cen = centres(tables)
    print("  band centres (Oklab hue):", ", ".join(f"{b} {cen[b]:.0f}°" for b in ORDER))
    # data[band][side][part] = 3 × rows × 72 (only the attribute's own effects)
    blob = []
    for band in ORDER:
        group = "a" if band in GROUPS["a"] else "b"
        mask = window(band, cen[band], cen)
        for side in (0, 1):
            for part in PARTS:
                blob.append(tables[(part, group, side)] * mask)
    data = np.stack(blob).astype("<f4")  # 8 bands × 2 sides × 3 parts → (48, 3, rows, 72)
    encoded = base64.b64encode(data.tobytes()).decode()
    lines = [
        "// Generated by tools/calibration/fit_hsl.py from Lightroom exports — don't edit by hand.",
        "",
        "extension HSLModel {",
        f"    static let hueBins = {HB}",
        f"    static let chromaEdges: [Double] = [{', '.join(f'{c:g}' for c in CHROMA)}]",
        "    /// Float32 little-endian: [band (app order)][side − / +][slider hue/sat/lum]",
        "    /// [effect: hue shift °, ln chroma ratio, ln lightness ratio][chroma row][hue bin], at ±50.",
        f'    static let encoded = "{encoded}"',
        "}",
        "",
    ]
    target.write_text("\n".join(lines))
    print(f"✓ Wrote {target} ({data.shape})")


if __name__ == "__main__":
    main()
