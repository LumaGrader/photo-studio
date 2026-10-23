#!/usr/bin/env python3
"""Preset test: the calibration image with a real preset's settings inside, plus variants
with one part of the preset switched off (LumaGrader only), to find which part differs.

Usage: python3 make_preset_test.py <kit> <preset.xmp> <number>
  <kit>/lightroom-import-preset/cal_<NN>_<name>.tif   → apply the same preset in Lightroom
  <kit>/preset-variants/cal_<NN>_<name>_no<part>.tif  → LumaGrader only
"""
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
from make_kit import save_tiff  # noqa: E402

NEUTRAL = {  # attribute prefixes/names → neutral value, per part
    "calibration": (r"(Red|Green|Blue)(Hue|Saturation)|ShadowTint", "0"),
    "hsl": (r"(Hue|Saturation|Luminance)Adjustment\w+", "0"),
    "satvib": (r"Saturation|Vibrance", "0"),
    "grading": (r"SplitToning\w+Saturation|ColorGrade\w+(Sat|Lum)", "0"),
    "basic": (r"(Exposure|Contrast|Highlights|Shadows|Whites|Blacks)2012", "0"),
    "presence": (r"Clarity2012|Texture|Dehaze", "0"),
    "grain": (r"GrainAmount", "0"),
}


def variant(xmp, part):
    if part == "curve":
        return re.sub(r"(<crs:ToneCurvePV2012(Red|Green|Blue)?>\s*<rdf:Seq>).*?(</rdf:Seq>)",
                      r"\1<rdf:li>0, 0</rdf:li><rdf:li>255, 255</rdf:li>\3", xmp, flags=re.S)
    pattern, value = NEUTRAL[part]
    return re.sub(r'crs:(%s)="[^"]*"' % pattern, lambda m: f'crs:{m.group(1)}="{value}"', xmp)


def main():
    kit, preset, number = Path(sys.argv[1]).expanduser(), Path(sys.argv[2]).expanduser(), int(sys.argv[3])
    xmp = preset.read_text()
    name = re.sub(r"\W+", "", preset.stem).lower()
    img = np.asarray(Image.open(kit / "source.tif").convert("RGB"))
    out_lr, out_var = kit / "lightroom-import-preset", kit / "preset-variants"
    out_lr.mkdir(exist_ok=True)
    out_var.mkdir(exist_ok=True)
    stem = f"cal_{number:02d}_{name}"
    save_tiff(img, out_lr / f"{stem}.tif", xmp)
    save_tiff(img, out_var / f"{stem}.tif", xmp)
    for part in list(NEUTRAL) + ["curve"]:
        save_tiff(img, out_var / f"{stem}_no{part}.tif", variant(xmp, part))
    print(f"✓ {out_lr / (stem + '.tif')} + {len(NEUTRAL) + 1} variants in {out_var}")


if __name__ == "__main__":
    main()
