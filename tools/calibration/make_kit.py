#!/usr/bin/env python3
"""LumaGrader slider calibration kit.

Builds one test image (your photo on the left, a grey ramp, grey steps and colour patches
on the right) and saves a copy of it per slider setting. Each copy carries its slider
values inside the file (XMP, the same format Lightroom writes), so:

  * Lightroom imports the copies with the sliders already set → export them all at once.
  * LumaGrader Photo Studio renders the same copies with `--calibrate`.

Usage:
  python3 make_kit.py <kit folder> [--photo photo.jpg]

Creates:
  <kit>/lightroom-import/   25 TIFFs to import into Lightroom (and render with LumaGrader)
  <kit>/presets/            the same settings as .xmp presets (fallback if Lightroom
                            ignores the settings inside the TIFFs)
  <kit>/adobe/              put the Lightroom exports here (16-bit TIFF, sRGB)
  <kit>/luma/               LumaGrader renders go here
  <kit>/source.tif          the test image with no settings
"""
import argparse
import colorsys
import uuid
from pathlib import Path

import numpy as np
from PIL import Image, ImageCms, TiffImagePlugin

W, H = 3000, 2000
HALF = W // 2

# Basic tone sliders and the values we measure. Exposure in EV, the rest −100…+100.
TESTS = [
    ("exposure", "Exposure2012", [-2.0, -1.0, 1.0, 2.0]),
    ("contrast", "Contrast2012", [-100, -50, 50, 100]),
    ("highlights", "Highlights2012", [-100, -50, 50, 100]),
    ("shadows", "Shadows2012", [-100, -50, 50, 100]),
    ("whites", "Whites2012", [-100, -50, 50, 100]),
    ("blacks", "Blacks2012", [-100, -50, 50, 100]),
]
TONE_KEYS = [t[1] for t in TESTS]

# Batch 2: in-between amounts + preset-like combinations (numbered after batch 1).
TESTS_2 = [
    ("whites", "Whites2012", [-75, -25, 25, 75]),
    ("blacks", "Blacks2012", [-75, -25, 25, 75]),
    ("shadows", "Shadows2012", [-75, -25, 25, 75]),
    ("highlights", "Highlights2012", [-75, -25, 25, 75]),
]
# Batch 3: Calibration primaries and global Saturation.
TESTS_3 = [(f"{c.lower()}{part.lower()}", f"{c}{part}", [-50, 50])
           for c in ("Red", "Green", "Blue") for part in ("Hue", "Saturation")] + [
    ("saturation", "Saturation", [-40, 40]),
]
# Batch 4: Color Mixer (HSL). Alternate bands per file so neighbouring bands never move
# together: group A = Red, Yellow, Aqua, Purple; group B = Orange, Green, Blue, Magenta.
HSL_GROUPS = {"a": ["Red", "Yellow", "Aqua", "Purple"], "b": ["Orange", "Green", "Blue", "Magenta"]}
HSL_PARTS = {"hue": "HueAdjustment", "sat": "SaturationAdjustment", "lightn": "LuminanceAdjustment"}
COMBOS = [
    ("comboa", {"Exposure2012": 0.3, "Contrast2012": 20, "Highlights2012": -40, "Shadows2012": 30,
                "Whites2012": 15, "Blacks2012": -25}),
    ("combob", {"Exposure2012": -0.3, "Contrast2012": 40, "Highlights2012": -60, "Shadows2012": -20,
                "Whites2012": -10, "Blacks2012": -40}),
    ("comboc", {"Exposure2012": 0.7, "Contrast2012": -30, "Highlights2012": -80, "Shadows2012": 60,
                "Whites2012": 40, "Blacks2012": 30}),
    ("combod", {"Exposure2012": 0, "Contrast2012": 60, "Highlights2012": 30, "Shadows2012": -50,
                "Whites2012": 50, "Blacks2012": -60}),
]


# ---------------------------------------------------------------- test image

def oklab_to_srgb(L, a, b):
    l_ = L + 0.3963377774 * a + 0.2158037573 * b
    m_ = L - 0.1055613458 * a - 0.0638541728 * b
    s_ = L - 0.0894841775 * a - 1.2914855480 * b
    l, m, s = l_ ** 3, m_ ** 3, s_ ** 3
    rgb = np.array([
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    ])
    return rgb


def encode(lin):
    lin = np.clip(lin, 0, 1)
    return np.where(lin <= 0.0031308, lin * 12.92, 1.055 * np.power(lin, 1 / 2.4) - 0.055)


def in_gamut_patch(L, C, hue_deg):
    """Oklch → sRGB 0…1, reducing chroma until it fits."""
    h = np.radians(hue_deg)
    for _ in range(40):
        rgb = oklab_to_srgb(L, C * np.cos(h), C * np.sin(h))
        if rgb.min() >= 0 and rgb.max() <= 1:
            return encode(rgb)
        C *= 0.93
    return encode(np.clip(rgb, 0, 1))


def synthetic_scene(w, h):
    """Stand-in when no photo is given: sky-to-shadow gradient with soft shapes."""
    y = np.linspace(0, 1, h)[:, None]
    x = np.linspace(0, 1, w)[None, :]
    base = 0.92 - 0.85 * y + 0.05 * np.sin(6 * x)
    for cx, cy, r, v in [(0.3, 0.35, 0.12, 0.15), (0.7, 0.6, 0.18, 0.85), (0.45, 0.8, 0.1, 0.05)]:
        d = np.sqrt((x - cx) ** 2 + ((y - cy) * h / w) ** 2)
        base = np.where(d < r, v + (base - v) * (d / r) ** 2, base)
    img = np.stack([base * 1.0, base * 0.95, base * 0.85], axis=-1)
    return (np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8)


def load_photo(path, w, h):
    import io
    im = Image.open(path).convert("RGB") if Image.open(path).mode != "RGB" else Image.open(path)
    icc = Image.open(path).info.get("icc_profile")
    if icc:  # convert to sRGB if the photo is tagged with another profile (e.g. Display P3)
        src = ImageCms.ImageCmsProfile(io.BytesIO(icc))
        im = ImageCms.profileToProfile(im, src, ImageCms.createProfile("sRGB"), outputMode="RGB")
    # Fill w × h (centre crop).
    scale = max(w / im.width, h / im.height)
    im = im.resize((round(im.width * scale), round(im.height * scale)), Image.LANCZOS)
    left, top = (im.width - w) // 2, (im.height - h) // 2
    return np.asarray(im.crop((left, top, left + w, top + h)).convert("RGB"))


def build_image(photo):
    img = np.zeros((H, W, 3), np.uint8)
    img[:, :HALF] = load_photo(photo, HALF, H) if photo else synthetic_scene(HALF, H)

    # Continuous grey ramp 0…255 (rows 0–200).
    ramp = np.round(np.linspace(0, 255, HALF)).astype(np.uint8)
    img[0:200, HALF:] = ramp[None, :, None]

    # 24 grey steps, evenly spaced in perceptual lightness (rows 200–600, 2 × 12 patches).
    pw = HALF // 12
    for i in range(24):
        L = i / 23
        v = encode(np.array([L ** 3]))[0]  # Oklab L for a grey is the cube root of linear
        r, c = divmod(i, 12)
        img[200 + r * 200:400 + r * 200, HALF + c * pw:HALF + (c + 1) * pw] = round(v * 255)

    # Colour patches: 12 hues × 3 lightness × 3 chroma (rows 600–2000).
    ph = (H - 600) // 9
    row = 0
    for L in (0.45, 0.65, 0.85):
        for C in (0.05, 0.11, 0.2):
            for c in range(12):
                rgb = in_gamut_patch(L, C, 15 + 30 * c)
                img[600 + row * ph:600 + (row + 1) * ph, HALF + c * pw:HALF + (c + 1) * pw] = np.round(rgb * 255)
            row += 1
    return img


# ---------------------------------------------------------------- settings

def fmt(key, value):
    if key == "Exposure2012":
        return f"{value:+.2f}"
    return f"{int(value):+d}" if value else "0"


def variants(batch=1):
    if batch == 4:
        out, n = [], 60
        for part, prefix in HSL_PARTS.items():
            for group, bands in HSL_GROUPS.items():
                for v in (-50, 50):
                    out.append((f"{n:02d}_{part}{group}_{'p' if v > 0 else 'm'}{abs(v)}",
                                {f"{prefix}{band}": v for band in bands}))
                    n += 1
        return out
    if batch == 3:
        out, n = [], 46
        for slider, key, values in TESTS_3:
            for v in values:
                out.append((f"{n:02d}_{slider}_{'p' if v > 0 else 'm'}{abs(v):g}", {key: v}))
                n += 1
        return out
    if batch == 2:
        out, n = [], 1 + sum(len(t[2]) for t in TESTS)
        for slider, key, values in TESTS_2:
            for v in values:
                out.append((f"{n:02d}_{slider}_{'p' if v > 0 else 'm'}{abs(v):g}", {key: v}))
                n += 1
        for name, values in COMBOS:
            out.append((f"{n:02d}_{name}", values))
            n += 1
        return out
    out = [("00_base", {})]
    n = 1
    for slider, key, values in TESTS:
        for v in values:
            tag = f"{'p' if v > 0 else 'm'}{abs(v):g}"
            out.append((f"{n:02d}_{slider}_{tag}", {key: v}))
            n += 1
    return out


COMMON = {
    "ProcessVersion": "11.0",
    "Sharpness": "0",
    "LuminanceSmoothing": "0",
    "ColorNoiseReduction": "0",
}


def crs_attributes(values):
    attrs = dict(COMMON)
    for key in TONE_KEYS:
        attrs[key] = fmt(key, values.get(key, 0))
    for key, value in values.items():  # colour settings (batch 3+)
        if key not in TONE_KEYS:
            attrs[key] = fmt(key, value)
    attrs["HasSettings"] = "True"
    return attrs


def xmp_packet(name, values, preset):
    attrs = crs_attributes(values)
    if preset:
        attrs = {
            "PresetType": "Normal", "Cluster": "", "UUID": uuid.uuid4().hex.upper(),
            "SupportsAmount": "False", "SupportsColor": "True", "SupportsMonochrome": "True",
            "SupportsHighDynamicRange": "True", "SupportsNormalDynamicRange": "True",
            "SupportsSceneReferred": "True", "SupportsOutputReferred": "True",
            "CameraModelRestriction": "", "Copyright": "", "ContactInfo": "", "Version": "15.0",
            **attrs,
        }
    lines = "\n".join(f'   crs:{k}="{v}"' for k, v in attrs.items())
    extra = ""
    if preset:
        extra = (f'\n   <crs:Name><rdf:Alt><rdf:li xml:lang="x-default">Cal {name}</rdf:li></rdf:Alt></crs:Name>'
                 '\n   <crs:Group><rdf:Alt><rdf:li xml:lang="x-default">LumaGrader Calibration</rdf:li></rdf:Alt></crs:Group>')
    return f"""<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="LumaGrader calibration">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
   xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
{lines}>{extra}
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
"""


def save_tiff(img, path, xmp=None):
    icc = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    ifd = TiffImagePlugin.ImageFileDirectory_v2()
    if xmp:
        ifd[700] = xmp.encode("utf-8")
        ifd.tagtype[700] = 1  # BYTE
    Image.fromarray(img, "RGB").save(path, format="TIFF", compression=None, icc_profile=icc, tiffinfo=ifd)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("kit")
    ap.add_argument("--photo", help="a typical photo of yours (JPEG/TIFF, sRGB), used on the left half")
    ap.add_argument("--batch", type=int, default=1,
                    help="2 = in-between amounts and combinations (needs batch 1's source.tif)")
    args = ap.parse_args()

    kit = Path(args.kit).expanduser()
    imports = kit / ("lightroom-import" if args.batch == 1 else f"lightroom-import-{args.batch}")
    for sub in (imports, kit / "presets", kit / "adobe", kit / "luma"):
        sub.mkdir(parents=True, exist_ok=True)

    if args.batch == 1:
        img = build_image(args.photo)
        save_tiff(img, kit / "source.tif")
    else:  # same pixels as batch 1
        img = np.asarray(Image.open(kit / "source.tif").convert("RGB"))
    items = variants(args.batch)
    for name, values in items:
        save_tiff(img, imports / f"cal_{name}.tif", xmp_packet(name, values, preset=False))
        (kit / "presets" / f"Cal {name}.xmp").write_text(xmp_packet(name, values, preset=True))
    print(f"✓ {len(items)} files in {imports}")
    for name, values in items:
        print(f"  cal_{name}: " + ", ".join(f"{k.replace('2012', '')} {fmt(k, v)}" for k, v in values.items()))


if __name__ == "__main__":
    main()
