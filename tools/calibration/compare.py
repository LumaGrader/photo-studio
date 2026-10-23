#!/usr/bin/env python3
"""Compare Lightroom exports with LumaGrader renders of the calibration kit.

Usage:
  python3 compare.py <kit folder>

Reads <kit>/source.tif, <kit>/adobe/*.tif or *.jpg (Lightroom) and <kit>/luma/*.tif (LumaGrader),
pairs them by the "cal_NN_" prefix and writes <kit>/report/:
  report.md     ΔE per slider setting, tone and saturation differences
  curves.csv    grey-ramp transfer curves (input sRGB 0…255 → output Oklab L) per app
  heat_*.png    where the two apps differ (brighter = bigger difference)

ΔE is Oklab distance × 100 (≈ 1 is barely visible, 2–3 noticeable side by side).
"""
import io
import re
import sys
from pathlib import Path

import numpy as np
import tifffile
from PIL import Image, ImageCms

HALF = 1500  # photo | chart split (see make_kit.py)
RAMP_ROWS = slice(20, 180)
PATCH_ROWS = slice(600, 2000)


def load(path):
    if path.suffix.lower() in (".jpg", ".jpeg"):
        im = Image.open(path).convert("RGB")
        icc = im.info.get("icc_profile") or Image.open(path).info.get("icc_profile")
        if icc:  # Lightroom may export in Display P3 / Adobe RGB → convert to sRGB
            src = ImageCms.ImageCmsProfile(io.BytesIO(icc))
            if "sRGB" not in ImageCms.getProfileDescription(src):
                im = ImageCms.profileToProfile(im, src, ImageCms.createProfile("sRGB"),
                                               renderingIntent=ImageCms.Intent.RELATIVE_COLORIMETRIC)
        a = np.asarray(im)
    else:
        a = tifffile.imread(path)
    if a.ndim == 2:
        a = np.stack([a] * 3, -1)
    a = a[..., :3]
    scale = 65535.0 if a.dtype == np.uint16 else 255.0
    return a.astype(np.float64) / scale


def decode(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def oklab(srgb):
    lin = decode(np.clip(srgb, 0, 1))
    m1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
                   [0.2119034982, 0.6806995451, 0.1073969566],
                   [0.0883024619, 0.2817188376, 0.6299787005]])
    m2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                   [1.9779984951, -2.4285922050, 0.4505937099],
                   [0.0259040371, 0.7827717662, -0.8086757660]])
    lms = np.cbrt(lin @ m1.T)
    return lms @ m2.T


def key(path):
    m = re.search(r"(cal_\d\d_[a-z]+_?[mp]?[\d.]*)", path.stem)
    return m.group(1) if m else None


def index(folder):
    out = {}
    for p in sorted(folder.iterdir()):
        if p.suffix.lower() not in (".tif", ".tiff", ".jpg", ".jpeg"):
            continue
        k = key(p)
        if k:
            out[k] = p
    return out


def ramp_curve(lab):
    """Median Oklab L per input level of the grey ramp, at 32 levels."""
    L = np.median(lab[RAMP_ROWS, HALF:, 0], axis=0)  # 1500 columns = input 0…255
    # Skip the outer columns: JPEG ringing at the photo edge and the image border.
    idx = np.linspace(12, L.size - 13, 32).round().astype(int)
    return idx * 255 / (L.size - 1), L[idx]


def chroma(lab):
    return np.hypot(lab[..., 1], lab[..., 2])


def main():
    kit = Path(sys.argv[1]).expanduser() if len(sys.argv) > 1 else Path(".")
    adobe, luma = index(kit / "adobe"), index(kit / "luma")
    pairs = sorted(k for k in adobe if k in luma)
    if not pairs:
        sys.exit(f"✗ No matching files in {kit/'adobe'} and {kit/'luma'} (names must start with cal_NN_)")
    out = kit / "report"
    out.mkdir(exist_ok=True)

    src = oklab(load(kit / "source.tif"))
    src_patch_c = chroma(src[PATCH_ROWS, HALF:])
    colourful = src_patch_c > 0.03

    rows, curves = [], ["variant,input,source_L,adobe_L,luma_L"]
    for k in pairs:
        a, b = oklab(load(adobe[k])), oklab(load(luma[k]))
        if a.shape != b.shape:
            print(f"! {k}: size differs {a.shape} vs {b.shape}, skipped")
            continue
        de = np.linalg.norm(a - b, axis=-1) * 100
        photo, chart = de[:, :HALF], de[:, HALF:]

        # Tone: mean lightness difference (luma − adobe), whole photo half.
        dL = (b[:, :HALF, 0] - a[:, :HALF, 0]).mean() * 100
        # Saturation: chroma relative to the source on the colour patches.
        ca = np.median(chroma(a[PATCH_ROWS, HALF:])[colourful] / src_patch_c[colourful])
        cb = np.median(chroma(b[PATCH_ROWS, HALF:])[colourful] / src_patch_c[colourful])

        x, s_L = ramp_curve(src)
        _, a_L = ramp_curve(a)
        _, b_L = ramp_curve(b)
        ramp_err = np.abs(a_L - b_L).max() * 100
        for xi, s0, a0, b0 in zip(x, s_L, a_L, b_L):
            curves.append(f"{k},{xi:.1f},{s0:.4f},{a0:.4f},{b0:.4f}")

        rows.append((k, de.mean(), np.percentile(de, 95), photo.mean(), chart.mean(), dL, ramp_err, ca, cb))
        heat = np.clip(de / 10, 0, 1)  # ΔE 10 = white
        Image.fromarray((heat * 255).astype(np.uint8)).resize((750, 500)).save(out / f"heat_{k}.png")
        print(f"✓ {k}: ΔE {de.mean():.2f}")

    lines = [
        "# LumaGrader vs Lightroom — Basic tone sliders", "",
        "ΔE = Oklab × 100 (1 ≈ barely visible). ΔL = LumaGrader minus Lightroom lightness on the photo",
        "(+ = LumaGrader brighter). Ramp = worst grey-ramp lightness gap. Sat = chroma vs. the source",
        "on the colour patches (1.00 = unchanged).", "",
        "| Setting | ΔE mean | ΔE p95 | ΔE photo | ΔE chart | ΔL photo | Ramp max | Sat LR | Sat Luma |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for r in rows:
        lines.append("| {} | {:.2f} | {:.2f} | {:.2f} | {:.2f} | {:+.2f} | {:.2f} | {:.3f} | {:.3f} |".format(*r))
    worst = sorted(rows, key=lambda r: -r[1])[:5]
    lines += ["", "**Biggest differences:** " + ", ".join(f"{r[0]} (ΔE {r[1]:.2f})" for r in worst)]
    (out / "report.md").write_text("\n".join(lines) + "\n")
    (out / "curves.csv").write_text("\n".join(curves) + "\n")
    print(f"✓ Report: {out/'report.md'}")


if __name__ == "__main__":
    main()
