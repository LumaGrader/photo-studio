import Foundation
import CoreImage
import simd

/// The LumaGrader develop shader, ported to a Core Image Metal kernel and compiled at
/// runtime by macOS. Per pixel, in this order (same as LumaGrader's WebGL shader):
///   white balance (non-RAW) → tone (exposure + shoulder, local Highlights/Shadows,
///   Whites/Blacks, Contrast) → gamut fit → Saturation/Vibrance → point curve → HSL →
///   Color Grading.
enum DevelopKernel {
    struct Kernels {
        let develop: CIKernel
        let baseLook: CIColorKernel
        /// Clarity / Texture / Dehaze: combines the photo with a blurred copy.
        let combine: CIKernel
        /// Post-crop vignette + grain.
        let finish: CIKernel
        /// Clipping warning overlay (J).
        let clip: CIKernel
    }

    /// The compiled kernels, or the reason they couldn't be built (the app then falls back
    /// to the basic Core Image pipeline).
    static let shared: Result<Kernels, Error> = {
        do {
            let kernels = try CIKernel.kernels(withMetalString: source)
            guard let develop = kernels.first(where: { $0.name == "drDevelop" }),
                  let baseLook = kernels.first(where: { $0.name == "drBaseLook" }) as? CIColorKernel,
                  let combine = kernels.first(where: { $0.name == "drCombine" }),
                  let finish = kernels.first(where: { $0.name == "drFinish" }),
                  let clip = kernels.first(where: { $0.name == "drClip" })
            else {
                return .failure(KernelError.missing)
            }
            return .success(Kernels(develop: develop, baseLook: baseLook, combine: combine, finish: finish, clip: clip))
        } catch {
            return .failure(error)
        }
    }()

    enum KernelError: LocalizedError {
        case missing
        var errorDescription: String? { "The develop kernels were not found after compiling." }
    }

    // MARK: - Darkroom Color (RAW base look)
    //
    // Calibrated on one Canon CR3 (indoor court, As Shot ≈ 4550 K): macOS RAW decode vs
    // Lightroom Adobe Color, both at zero settings, aligned pixel by pixel.
    //  - Tone (sRGB-encoded luminance): e' = e + e(1−e)(a + b·e) — Lightroom is brighter
    //    in the mids and upper mids.
    //  - Colour (Oklab): chroma gain and hue shift per hue, 12 knots at 15° + 30°·i,
    //    periodic Catmull-Rom, faded out for near-greys. Lightroom is ~11% less saturated
    //    and its oranges sit ~5° toward red.
    // Measured: Oklab ΔE 0.040 → 0.031 at zero settings. One photo — refine with more pairs.
    static let lookTone = (a: -0.0173, b: 0.3126)
    static let lookGains: [Double] = [0.809, 0.859, 0.928, 0.882, 0.845, 0.866, 0.872, 0.861, 0.867, 0.856, 0.792, 0.807]
    static let lookShifts: [Double] = [-0.5, -0.2, -4.6, -5.5, -2.0, -1.8, -1.1, 1.1, -3.6, -6.3, -3.7, -1.2]

    /// Applies a kernel whether macOS compiled it as a colour kernel or a general one.
    static func run(_ kernel: CIKernel, extent: CGRect, arguments: [Any], roi: CIKernelROICallback? = nil) -> CIImage? {
        if let color = kernel as? CIColorKernel {
            return color.apply(extent: extent, arguments: arguments)
        }
        return kernel.apply(extent: extent, roiCallback: roi ?? { _, rect in rect }, arguments: arguments)
    }

    // MARK: - Presence (ported from lumagrader webgl COMBINE_FRAG_SRC)
    //
    // Each effect blurs the photo (radius in pixels of a 1600 px-long image, scaled to the
    // real size) and combines: Dehaze (dark-channel haze from a 40 px blur), Texture (fine,
    // low-contrast detail, 2.5 px), Clarity (mid-tone local contrast, 18 px). Luminance only.

    static func applyPresence(_ kernel: CIKernel, to input: CIImage, effects e: EffectsSettings) -> CIImage {
        let extent = input.extent
        let scale = max(extent.width, extent.height) / 1600
        let passes: [(mode: Double, amount: Double, radius: Double)] = [
            (4, e.dehaze / 100, 40),
            (3, e.texture / 100 * (e.texture > 0 ? 1.6 : 1.0), 2.5),
            (2, e.clarity / 100 * (e.clarity > 0 ? 1.3 : 0.9), 18),
        ]
        var image = input
        for pass in passes where pass.amount != 0 {
            let blurred = image.clampedToExtent()
                .applyingGaussianBlur(sigma: pass.radius * Double(scale))
                .cropped(to: extent)
            let current = image
            if let combined = run(kernel, extent: extent,
                                  arguments: [current, blurred, NSNumber(value: pass.amount), NSNumber(value: pass.mode)],
                                  roi: { _, rect in rect }) {
                image = combined.cropped(to: extent)
            }
        }
        return image
    }

    // MARK: - Vignette + grain (ported from lumagrader color.js vignetteWeight / grainAt)

    static func applyFinish(_ kernel: CIKernel, to image: CIImage, effects e: EffectsSettings) -> CIImage {
        let extent = image.extent
        let w = Double(extent.width), h = Double(extent.height)
        let longSide = max(w, h)
        let cells = 1300 * pow(2, (25 - min(max(e.grainSize, 0), 100)) / 25)
        let amplitude = pow(min(max(e.grain, 0), 100) / 100, 1.2) * 0.12
        let arguments: [Any] = [
            image,
            CIVector(x: CGFloat(e.vignette / 100), y: CGFloat(e.vignetteMidpoint / 100),
                     z: CGFloat(e.vignetteRoundness / 100), w: CGFloat(e.vignetteFeather / 100)),
            NSNumber(value: e.vignetteHighlights / 100),
            CIVector(x: CGFloat(amplitude), y: CGFloat(cells * w / longSide),
                     z: CGFloat(cells * h / longSide), w: CGFloat(e.grainRoughness / 100)),
            CIVector(x: extent.minX, y: extent.minY, z: extent.width, w: extent.height),
        ]
        return run(kernel, extent: extent, arguments: arguments)?.cropped(to: extent) ?? image
    }

    /// Red where a channel clips to white, blue where all channels are black (like Lightroom's J).
    static func applyClipping(_ kernel: CIKernel, to image: CIImage) -> CIImage {
        run(kernel, extent: image.extent, arguments: [image])?.cropped(to: image.extent) ?? image
    }

    // MARK: - Calibration (red/green/blue primaries)

    // Fitted on a Lightroom vs Darkroom pair (Teal Film preset: Blue Hue −25, Blue Sat +20,
    // HSL Blue −45, Shadows grading 190°/25), Oklab ab error 0.022 → 0.015.
    static let calibrationHueScale = 2.4        // rad per 100 (was 0.6)
    static let calibrationSaturationScale = 0.15 // chroma per 100 (was 0.6)

    /// 3×3 matrix (linear RGB) that moves the primaries in Oklab hue/chroma and keeps
    /// white white: columns = new primaries, rescaled so (1,1,1) maps to (1,1,1).
    static func calibrationMatrix(_ cal: CalibrationSettings) -> simd_double3x3 {
        guard !cal.isNeutral else { return matrix_identity_double3x3 }
        let adjustments = [(cal.redHue, cal.redSaturation), (cal.greenHue, cal.greenSaturation),
                           (cal.blueHue, cal.blueSaturation)]
        var columns: [SIMD3<Double>] = []
        for (i, (hue, saturation)) in adjustments.enumerated() {
            var primary = SIMD3<Double>(0, 0, 0)
            primary[i] = 1
            var lab = Oklab.fromLinear(primary)
            let chroma = (lab.y * lab.y + lab.z * lab.z).squareRoot() * max(0, 1 + saturation / 100 * calibrationSaturationScale)
            let angle = atan2(lab.z, lab.y) + hue / 100 * calibrationHueScale
            lab.y = cos(angle) * chroma
            lab.z = sin(angle) * chroma
            columns.append(Oklab.toLinear(lab))
        }
        let m = simd_double3x3(columns[0], columns[1], columns[2])
        guard abs(m.determinant) > 1e-6 else { return matrix_identity_double3x3 }
        let w = m.inverse * SIMD3<Double>(1, 1, 1)
        return simd_double3x3(columns[0] * w.x, columns[1] * w.y, columns[2] * w.z)
    }

    /// Extra colour table, 10 × 1 pixels: two per Point Color — (L, chroma, hue, range) and
    /// (hue, saturation, luminance shifts, 0) as −1…1 — then the B&W mix (8 bands, 2 pixels).
    static func pointColorImage(_ points: [PointColor], bwMix: [Double]) -> CIImage {
        var values = [Float](repeating: 0, count: 10 * 4)
        for (i, v) in bwMix.prefix(8).enumerated() {
            values[32 + i] = Float(v)
        }
        for (i, p) in points.prefix(PointColor.maxCount).enumerated() {
            let a = i * 8
            values[a] = Float(p.lightness)
            values[a + 1] = Float(p.chroma)
            values[a + 2] = Float(p.hue)
            values[a + 3] = Float(min(max(p.range, 0), 100) / 100)
            values[a + 4] = Float(p.hueShift / 100)
            values[a + 5] = Float(p.saturationShift / 100)
            values[a + 6] = Float(p.luminanceShift / 100)
            values[a + 7] = 0
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: 10 * 16,
                       size: CGSize(width: 10, height: 1), format: .RGBAf, colorSpace: nil)
    }

    /// Applies the Darkroom Color look to a linear RAW decode.
    static func applyBaseLook(_ kernel: CIColorKernel, to image: CIImage) -> CIImage? {
        func knots(_ values: [Double], _ start: Int) -> CIVector {
            CIVector(x: CGFloat(values[start]), y: CGFloat(values[start + 1]),
                     z: CGFloat(values[start + 2]), w: CGFloat(values[start + 3]))
        }
        return kernel.apply(extent: image.extent, arguments: [
            image,
            knots(lookGains, 0), knots(lookGains, 4), knots(lookGains, 8),
            knots(lookShifts, 0), knots(lookShifts, 4), knots(lookShifts, 8),
            CIVector(x: CGFloat(lookTone.a), y: CGFloat(lookTone.b)),
        ])
    }

    // MARK: - Slider calibration
    //
    // Re-fitted for the macOS RAW decode + Darkroom Color (same CR3, Highlights −60,
    // Shadows +40, Contrast +30 vs Lightroom): Oklab ΔE 0.046 → 0.033, saturation matched.
    // Lightroom's Contrast also raises saturation (it works on RGB channels), modelled as a
    // chroma factor 1 + κ·contrast (half as strong for negative contrast).
    static let shadowsGainEV = 0.729       // LumaGrader: 1.26
    static let highlightsGainEV = 0.452    // LumaGrader: 0.44
    static let highlightsCenterEV = -1.292 // LumaGrader: -1.83
    static let contrastPivot = 0.604       // LumaGrader: 0.46
    static let contrastSaturation = 1.018  // κ

    static var errorMessage: String? {
        if case let .failure(error) = shared { return error.localizedDescription }
        return nil
    }

    /// Identity point-curve table (256 × 1), used until the Tone Curve editor exists.
    static let identityCurve: CIImage = {
        var values = [Float](repeating: 0, count: 256 * 4)
        for i in 0..<256 {
            let v = Float(i) / 255
            values[i * 4] = v
            values[i * 4 + 1] = v
            values[i * 4 + 2] = v
            values[i * 4 + 3] = 1
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: 256 * 16,
                       size: CGSize(width: 256, height: 1), format: .RGBAf, colorSpace: nil)
    }()

    /// Tone curves as a 256 × 1 table. Like Lightroom: region (parametric) curve, then the
    /// RGB point curve, then each channel curve on its result: out_r = Red(RGB(Param(r))).
    static func curveImage(_ curve: ToneCurvePoints) -> CIImage {
        let master = CurveSpline(curve.rgb)
        let channels = [curve.red, curve.green, curve.blue].map { ToneCurvePoints.isIdentity($0) ? nil : CurveSpline($0) }
        var values = [Float](repeating: 0, count: 256 * 4)
        for i in 0..<256 {
            let m = master.value(at: 255 * curve.parametric.value(at: Double(i) / 255))
            for c in 0..<3 {
                values[i * 4 + c] = Float((channels[c]?.value(at: m) ?? m) / 255)
            }
            values[i * 4 + 3] = 1
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: 256 * 16,
                       size: CGSize(width: 256, height: 1), format: .RGBAf, colorSpace: nil)
    }

    /// A = 1, B = 0 everywhere → local base = the pixel itself (used if the map is missing).
    static func flatCoefficients(_ extent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1)).cropped(to: extent)
    }

    /// Applies the kernel. `image` is linear (Core Image working space).
    static func apply(
        _ kernel: CIKernel,
        to image: CIImage,
        settings s: DevelopSettings,
        isRaw: Bool,
        localBase: CIImage?
    ) -> CIImage? {
        let extent = image.extent
        let coefficients = localBase ?? flatCoefficients(extent)
        let curveActive = !s.curve.isIdentity
        let curve = curveActive ? curveImage(s.curve) : identityCurve

        // White balance matrix (non-RAW only; RAW white balance happens in the decoder).
        var wb = matrix_identity_double3x3
        if !isRaw, let matrix = LumaEngine.whiteBalanceMatrix(temperature: s.temperature ?? 0, tint: s.tint ?? 0) {
            wb = matrix
        }
        // Calibration runs right after white balance.
        wb = calibrationMatrix(s.calibration) * wb
        let points = s.activePointColors
        let pointTable = pointColorImage(points, bwMix: s.bwMix)
        // simd matrices are column-major: row i = (col0[i], col1[i], col2[i]).
        func row(_ i: Int) -> CIVector {
            CIVector(x: CGFloat(wb.columns.0[i]), y: CGFloat(wb.columns.1[i]), z: CGFloat(wb.columns.2[i]))
        }

        let hsl = s.isHSLActive
        let grade = LumaEngine.gradeUniforms(s.colorGrade)
        let gradeActive = s.colorGrade.isActive

        func vec4(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> CIVector {
            CIVector(x: CGFloat(a), y: CGFloat(b), z: CGFloat(c), w: CGFloat(d))
        }
        func bands(_ values: [Double], _ start: Int) -> CIVector {
            vec4(values[start], values[start + 1], values[start + 2], values[start + 3])
        }

        let arguments: [Any] = [
            image,
            coefficients,
            curve,
            pointTable,
            vec4(s.exposure, s.shadows / 100, s.highlights / 100, LumaEngine.shoulderA(ev: s.exposure)),
            vec4(s.whites / 100, s.blacks / 100, s.contrast / 100, (s.highlights != 0 || s.shadows != 0) ? 1 : 0),
            vec4(shadowsGainEV, highlightsGainEV, highlightsCenterEV, contrastPivot),
            CIVector(x: CGFloat(contrastSaturation), y: CGFloat(points.count)),
            row(0), row(1), row(2),
            vec4(s.saturation / 100, s.vibrance / 100, curveActive ? 1 : 0, hsl ? 1 : 0),
            bands(s.hslHue, 0), bands(s.hslHue, 4),
            bands(s.hslSaturation, 0), bands(s.hslSaturation, 4),
            bands(s.hslLuminance, 0), bands(s.hslLuminance, 4),
            vec4(grade.tints[0].x, grade.tints[0].y, grade.tints[1].x, grade.tints[1].y),
            vec4(grade.tints[2].x, grade.tints[2].y, grade.tints[3].x, grade.tints[3].y),
            vec4(grade.luminances[0], grade.luminances[1], grade.luminances[2], grade.luminances[3]),
            vec4(grade.blending, grade.balance, gradeActive ? 1 : 0, s.blackWhite ? 1 : 0),
        ]

        return kernel.apply(
            extent: extent,
            roiCallback: { index, rect in
                switch index {
                case 0: return rect
                case 1: return coefficients.extent
                case 2: return curve.extent
                default: return pointTable.extent
                }
            },
            arguments: arguments)
    }

    // MARK: - Metal source

    static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    constant float DR_HSL_C[9] = { 0.0, 30.0, 60.0, 120.0, 180.0, 240.0, 275.0, 320.0, 360.0 };

    inline float drSig(float x) { return 1.0 / (1.0 + exp(-x)); }
    inline float drEnc1(float v) { v = max(v, 0.0); return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055; }
    inline float drDec1(float v) { v = max(v, 0.0); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4); }
    inline float3 drEnc(float3 c) { return float3(drEnc1(c.r), drEnc1(c.g), drEnc1(c.b)); }
    inline float3 drDec(float3 c) { return float3(drDec1(c.r), drDec1(c.g), drDec1(c.b)); }
    inline float drLuma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
    inline float drSmooth(float a, float b, float x) { float t = clamp((x - a) / (b - a), 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }

    // Desaturate toward luminance instead of clipping channels (keeps hue).
    inline float3 drFitGamut(float3 c) {
      c = max(c, 0.0);
      float m = max(c.r, max(c.g, c.b));
      if (m <= 1.0) return c;
      float y = drLuma(c);
      if (y >= 1.0) return float3(1.0);
      float t = (1.0 - y) / (m - y);
      return max(y + (c - y) * t, 0.0);
    }

    // ---- Tone (tone.js) ----
    // Local zones on the edge-aware base (EV, 0 = white): bell-shaped, fitted to Lightroom.
    // tune = (shadows gain EV, highlights gain EV, highlights centre EV, contrast pivot).
    inline float drLocalGain(float v, float sh, float hi, float4 tune) {
      float g = 0.0;
      if (sh != 0.0) {
        float w = (1.0 - drSig((v + 3.49) / 0.77)) * drSig((v + 4.68) / 0.36);
        g += sh * tune.x * w;
      }
      if (hi != 0.0) {
        float w = drSig((v - tune.z) / 0.66);
        float fall = drSig((v + 0.22) / 0.1);
        float back = drSig((v - 0.15) / 0.2);
        w *= 1.0 - 0.85 * fall * (1.0 - back);
        g += hi * tune.y * w;
      }
      return g;
    }

    inline float drGlobalGain(float v, float wh, float bl) {
      float g = 0.0;
      if (bl != 0.0) g += bl * 1.5 * (1.0 - drSig((v + 5.5) / 0.8));
      if (wh != 0.0) g += wh * 0.8 * drSig((v + 0.3) / 0.6);
      return g;
    }

    // Logistic S-curve (k = 6) in sRGB-encoded space around `pivot`, anchored at 0 and 1.
    inline float drContrast(float p, float c, float pivot) {
      if (c == 0.0) return p;
      float s0 = drSig(-6.0 * pivot);
      float s1 = drSig(6.0 * (1.0 - pivot));
      float a = abs(c);
      if (p >= 1.0) {
        float slopeAt1 = 6.0 * s1 * (1.0 - s1) / (s1 - s0);
        float slope = c > 0.0 ? slopeAt1 : 1.0 / slopeAt1;
        return 1.0 + (p - 1.0) * (1.0 + a * (slope - 1.0));
      }
      float q = max(0.0, p);
      float target;
      if (c > 0.0) {
        target = (drSig(6.0 * (q - pivot)) - s0) / (s1 - s0);
      } else {
        float t = clamp(q * (s1 - s0) + s0, 1e-6, 1.0 - 1e-6);
        target = pivot + log(t / (1.0 - t)) / 6.0;
      }
      return p + a * (target - p);
    }

    // +Exposure highlight shoulder: tones above the knee roll into white instead of clipping.
    inline float drShoulder(float x, float ev, float a) {
      float k = 0.4;
      if (ev <= 0.0 || x <= k || a <= 0.0) return x;
      float t = exp2(ev) - k;
      if (t <= 1.0 - k) return x;
      return k + (1.0 - k) * (1.0 - exp(-a * min(x - k, t))) / (1.0 - exp(-a * t));
    }

    inline float drGlobalToneY(float v, float ev, float a, float wh, float bl, float con, float pivot) {
      if (ev > 0.0) v = log2(max(drShoulder(exp2(v), ev, a), 1e-8));
      float y1 = exp2(v + drGlobalGain(v, wh, bl));
      float p = drContrast(drEnc1(y1), con, pivot);
      return p <= 0.0 ? 0.0 : drDec1(p);
    }

    // ---- Color (color.js) ----
    inline float drGrey(float3 c) { return drEnc1(drLuma(drDec(max(c, 0.0)))); }

    inline float drMaxChromaScale(float3 c, float l) {
      float k = 1e6;
      for (int i = 0; i < 3; i++) {
        float d = c[i] - l;
        if (d > 1e-6) k = min(k, (1.0 - l) / d);
        else if (d < -1e-6) k = min(k, l / -d);
      }
      return k;
    }

    inline float3 drScaleChroma(float3 c, float k) {
      float l = drGrey(c);
      if (k > 1.0) k = min(k, max(1.0, drMaxChromaScale(c, l)));
      k = max(0.0, k);
      return l + (c - l) * k;
    }

    inline float2 drHueSat(float3 c) {
      float mx = max(c.r, max(c.g, c.b));
      float mn = min(c.r, min(c.g, c.b));
      float ch = mx - mn;
      if (ch <= 1e-6) return float2(0.0);
      float h;
      if (mx == c.r) h = fmod((c.g - c.b) / ch + 6.0, 6.0);
      else if (mx == c.g) h = (c.b - c.r) / ch + 2.0;
      else h = (c.r - c.g) / ch + 4.0;
      h *= 60.0;
      if (h < 0.0) h += 360.0;
      return float2(h, mx > 0.0 ? ch / mx : 0.0);
    }

    inline float3 drWithHue(float3 c, float h) {
      float mx = max(c.r, max(c.g, c.b));
      float mn = min(c.r, min(c.g, c.b));
      float ch = mx - mn;
      float hp = fmod(fmod(h, 360.0) + 360.0, 360.0) / 60.0;
      float x = ch * (1.0 - abs(fmod(hp, 2.0) - 1.0));
      float3 o;
      if (hp < 1.0) o = float3(ch, x, 0.0);
      else if (hp < 2.0) o = float3(x, ch, 0.0);
      else if (hp < 3.0) o = float3(0.0, ch, x);
      else if (hp < 4.0) o = float3(0.0, x, ch);
      else if (hp < 5.0) o = float3(x, 0.0, ch);
      else o = float3(ch, 0.0, x);
      return o + mn;
    }

    inline float drSatVibFactor(float3 c, float sat, float vib) {
      float k = 1.0 + sat;
      if (vib != 0.0) {
        float2 hs = drHueSat(c);
        if (vib > 0.0) {
          float dh = abs(hs.x - 28.0);
          if (dh > 180.0) dh = 360.0 - dh;
          float skin = max(0.0, 1.0 - dh / 30.0) * drSmooth(0.08, 0.3, hs.y);
          k *= 1.0 + vib * 1.3 * (1.0 - hs.y) * (1.0 - hs.y) * (1.0 - 0.55 * skin);
        } else {
          k *= 1.0 + vib * 0.85;
        }
      }
      return k;
    }

    inline float drBand(float4 a, float4 b, int i) { return i < 4 ? a[i] : b[i - 4]; }

    inline float3 drOklab(float3 c) {
      float3 lms = float3(
        dot(c, float3(0.4122214708, 0.5363325363, 0.0514459929)),
        dot(c, float3(0.2119034982, 0.6806995451, 0.1073969566)),
        dot(c, float3(0.0883024619, 0.2817188376, 0.6299787005)));
      lms = pow(max(lms, 0.0), float3(1.0 / 3.0));
      return float3(
        dot(lms, float3(0.2104542553, 0.7936177850, -0.0040720468)),
        dot(lms, float3(1.9779984951, -2.4285922050, 0.4505937099)),
        dot(lms, float3(0.0259040371, 0.7827717662, -0.8086757660)));
    }

    inline float3 drFromOklab(float3 o) {
      float3 lms = float3(
        o.x + 0.3963377774 * o.y + 0.2158037573 * o.z,
        o.x - 0.1055613458 * o.y - 0.0638541728 * o.z,
        o.x - 0.0894841775 * o.y - 1.2914855480 * o.z);
      lms = lms * lms * lms;
      return float3(
        dot(lms, float3(4.0767416621, -3.3077115913, 0.2309699292)),
        dot(lms, float3(-1.2684380046, 2.6097574011, -0.3413193965)),
        dot(lms, float3(-0.0041960863, -0.7034186147, 1.7076147010)));
    }

    inline float drBandMix(float4 a, float4 b, float hue) {
      int i0 = 7;
      for (int i = 0; i < 8; i++) { if (hue >= DR_HSL_C[i] && hue < DR_HSL_C[i + 1]) { i0 = i; } }
      float t = drSmooth(0.0, 1.0, (hue - DR_HSL_C[i0]) / (DR_HSL_C[i0 + 1] - DR_HSL_C[i0]));
      int i1 = i0 == 7 ? 0 : i0 + 1;
      return mix(drBand(a, b, i0), drBand(a, b, i1), t);
    }

    [[ stitchable ]] float4 drDevelop(coreimage::sampler src, coreimage::sampler coef, coreimage::sampler curve,
                                      coreimage::sampler points,
                                      float4 tone1, float4 tone2, float4 tune, float2 extra,
                                      float3 wb0, float3 wb1, float3 wb2,
                                      float4 color, float4 hueA, float4 hueB, float4 satA, float4 satB,
                                      float4 lumA, float4 lumB, float4 gradeT01, float4 gradeT23,
                                      float4 gradeL, float4 gradeMisc, coreimage::destination dest) {
      float kappa = extra.x;
      float pointCount = extra.y;
      float4 px = src.sample(src.coord());
      float3 lin = max(px.rgb, 0.0);
      lin = max(float3(dot(wb0, lin), dot(wb1, lin), dot(wb2, lin)), 0.0);

      float ev = tone1.x, sh = tone1.y, hi = tone1.z, shoulder = tone1.w;
      float wh = tone2.x, bl = tone2.y, con = tone2.z;
      bool tone = ev != 0.0 || sh != 0.0 || hi != 0.0 || wh != 0.0 || bl != 0.0 || con != 0.0;
      if (tone) {
        float y0 = drLuma(lin);
        if (y0 > 1e-8) {
          float v0 = max(log2(y0), -14.0);
          float v = log2(y0) + ev;
          if (tone2.w > 0.5) {
            float2 ab = coef.sample(coef.transform(dest.coord())).rg;
            float base = ab.x * v0 + ab.y + ev;
            v += drLocalGain(clamp(base, -14.0, 6.0), sh, hi, tune);
          }
          float yf = drGlobalToneY(v, ev, shoulder, wh, bl, con, tune.w);
          lin *= yf / y0;
        } else {
          lin = float3(0.0);
        }
      }

      float3 c = drEnc(drFitGamut(lin));

      // Lightroom's Contrast also changes saturation (it works on RGB channels), less so
      // for colours that are already saturated.
      if (con != 0.0) {
        float s0 = drHueSat(c).y;
        c = drScaleChroma(c, 1.0 + kappa * con * (con > 0.0 ? 1.0 : 0.5) * (1.0 - s0 * s0));
      }

      if (color.x != 0.0 || color.y != 0.0) c = drScaleChroma(c, drSatVibFactor(c, color.x, color.y));
      c = clamp(c, 0.0, 1.0);

      if (color.z > 0.5) {
        float3 cu = c * 255.0 + 0.5;
        c.r = curve.sample(curve.transform(float2(cu.r, 0.5))).r;
        c.g = curve.sample(curve.transform(float2(cu.g, 0.5))).g;
        c.b = curve.sample(curve.transform(float2(cu.b, 0.5))).b;
      }

      if (gradeMisc.w > 0.5) {
        // Black & White: luminance, brightened or darkened per original colour (B&W mix).
        float4 monoA = points.sample(points.transform(float2(8.5, 0.5)));
        float4 monoB = points.sample(points.transform(float2(9.5, 0.5)));
        float2 hs = drHueSat(c);
        float y = drLuma(drDec(c));
        if (hs.y > 0.0) {
          float m = drBandMix(monoA, monoB, hs.x) * drSmooth(0.0, 0.5, hs.y);
          y *= exp2(m / 100.0 * 1.6);
        }
        c = clamp(float3(drEnc1(y)), 0.0, 1.0);
      } else if (color.w > 0.5) {
        float2 hs = drHueSat(c);
        float fade = drSmooth(0.03, 0.2, hs.y);
        if (fade > 0.0) {
          int i0 = 7;
          for (int i = 0; i < 8; i++) { if (hs.x >= DR_HSL_C[i] && hs.x < DR_HSL_C[i + 1]) { i0 = i; } }
          float t = drSmooth(0.0, 1.0, (hs.x - DR_HSL_C[i0]) / (DR_HSL_C[i0 + 1] - DR_HSL_C[i0]));
          int i1 = i0 == 7 ? 0 : i0 + 1;
          float dh = mix(drBand(hueA, hueB, i0), drBand(hueA, hueB, i1), t) * fade;
          float ds = mix(drBand(satA, satB, i0), drBand(satA, satB, i1), t) * fade;
          float dl = mix(drBand(lumA, lumB, i0), drBand(lumA, lumB, i1), t) * fade;
          if (dh != 0.0) c = drWithHue(c, hs.x + dh * 0.6);
          if (ds != 0.0) c = drScaleChroma(c, 1.0 + ds / 100.0);
          if (dl != 0.0) c = drEnc(drFitGamut(drDec(c) * exp2(dl / 100.0 * 1.2)));
        }
      }

      // Point Color: up to 4 picked colours, matched by hue, chroma and lightness.
      int np = int(pointCount + 0.5);
      if (np > 0 && gradeMisc.w < 0.5) {
        float3 o = drOklab(drDec(c));
        float cc = length(o.yz);
        float hc = atan2(o.z, o.y) * 57.29577951;
        float cfade = drSmooth(0.005, 0.03, cc);
        bool changed = false;
        for (int i = 0; i < 4; i++) {
          if (i >= np) break;
          float4 p0 = points.sample(points.transform(float2(float(2 * i) + 0.5, 0.5)));
          float4 p1 = points.sample(points.transform(float2(float(2 * i) + 1.5, 0.5)));
          float r = p0.w;
          float dh = abs(fmod(hc - p0.z + 540.0, 360.0) - 180.0);
          float hw = 10.0 + 45.0 * r;
          float w = 1.0 - drSmooth(hw * 0.4, hw, dh);
          w *= 1.0 - drSmooth(0.05 + 0.1 * r, 0.12 + 0.2 * r, abs(cc - p0.y));
          w *= 1.0 - drSmooth(0.15 + 0.25 * r, 0.3 + 0.45 * r, abs(o.x - p0.x));
          w *= cfade;
          if (w > 0.0) {
            hc += p1.x * 30.0 * w;
            cc *= max(0.0, 1.0 + p1.y * w);
            o.x += p1.z * 0.2 * w;
            changed = true;
          }
        }
        if (changed) {
          float hr = hc * 0.01745329252;
          o.yz = float2(cos(hr), sin(hr)) * cc;
          o.x = max(o.x, 0.0);
          c = clamp(drEnc(drFitGamut(drFromOklab(o))), 0.0, 1.0);
        }
      }

      if (gradeMisc.z > 0.5) {
        float3 o = drOklab(drDec(c));
        float l = o.x;
        float shift = -gradeMisc.y * 0.15;
        float width = 0.06 + 0.22 * gradeMisc.x;
        float ws = 1.0 - drSmooth(0.49 + shift - width, 0.49 + shift + width, l);
        float whw = drSmooth(0.66 + shift - width, 0.66 + shift + width, l);
        float wm = drSmooth(0.0, 1.0, 1.0 - abs(l - (0.575 + shift)) / (0.22 + 0.3 * gradeMisc.x));
        float fade = drSmooth(0.0, 0.25, l) * (1.0 - 0.7 * drSmooth(0.93, 1.0, l));
        float4 w = float4(ws, wm, whw, 1.0);
        o.yz += (gradeT01.xy * w.x + gradeT01.zw * w.y + gradeT23.xy * w.z + gradeT23.zw * w.w) * fade;
        o.x += dot(gradeL, w);
        o.x = max(o.x, 0.0);
        c = drEnc(drFitGamut(drFromOklab(o)));
      }

      return float4(drDec(clamp(c, 0.0, 1.0)), px.a);
    }

    // ---- Darkroom Color: RAW base look (see lookTone / lookGains / lookShifts) ----
    inline float drKnot(float4 a, float4 b, float4 c, int i) {
      i = (i % 12 + 12) % 12;
      return i < 4 ? a[i] : (i < 8 ? b[i - 4] : c[i - 8]);
    }

    // Periodic Catmull-Rom through 12 knots at hues 15° + 30°·i.
    inline float drCatmull(float4 a, float4 b, float4 c, float h) {
      float t = fmod(h - 15.0 + 720.0, 360.0) / 30.0;
      int i = int(floor(t));
      float u = t - float(i);
      float p0 = drKnot(a, b, c, i - 1), p1 = drKnot(a, b, c, i), p2 = drKnot(a, b, c, i + 1), p3 = drKnot(a, b, c, i + 2);
      return 0.5 * ((2.0 * p1) + (-p0 + p2) * u + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * u * u
                    + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * u * u * u);
    }

    [[ stitchable ]] float4 drBaseLook(coreimage::sample_t s, float4 g0, float4 g1, float4 g2,
                                       float4 h0, float4 h1, float4 h2, float2 tone) {
      float3 lin = max(s.rgb, 0.0);
      float y = drLuma(lin);
      if (y > 1e-8) {
        float e = drEnc1(y);
        if (e < 1.0) {
          float e2 = e + e * (1.0 - e) * (tone.x + tone.y * e);
          lin *= drDec1(e2) / y;
        }
      }
      float3 o = drOklab(lin);
      float chroma = length(o.yz);
      if (chroma > 1e-6) {
        float hue = atan2(o.z, o.y) * 57.29577951;
        if (hue < 0.0) hue += 360.0;
        float fade = drSmooth(0.01, 0.045, chroma);
        float gain = 1.0 + (drCatmull(g0, g1, g2, hue) - 1.0) * fade;
        float shift = drCatmull(h0, h1, h2, hue) * fade;
        float h2r = (hue + shift) * 0.01745329252;
        o.yz = float2(cos(h2r), sin(h2r)) * chroma * gain;
        lin = drFromOklab(o);
      }
      return float4(max(lin, 0.0), s.a);
    }

    // ---- Presence: Clarity (mode 2), Texture (3), Dehaze (4) ----
    [[ stitchable ]] float4 drCombine(coreimage::sampler orig, coreimage::sampler blur,
                                      float amount, float mode, coreimage::destination dest) {
      float4 o4 = orig.sample(orig.coord());
      float3 o = drEnc(clamp(o4.rgb, 0.0, 1.0));
      float3 b = drEnc(clamp(blur.sample(blur.coord()).rgb, 0.0, 1.0));
      float3 r;
      if (mode < 3.5) {
        float lo = drLuma(o);
        float d = lo - drLuma(b);
        float w = 1.0;
        if (mode < 2.5) {
          d = clamp(d, -0.12, 0.12);
          w = mix(0.2, 1.0, clamp(4.0 * lo * (1.0 - lo), 0.0, 1.0));
        } else {
          d *= 1.0 - drSmooth(0.04, 0.14, abs(d));
        }
        r = o + amount * d * w;
      } else {
        float haze = min(min(b.r, b.g), b.b);
        float t = max(1.0 - amount * 0.9 * haze, 0.3);
        r = (o - 0.95) / t + 0.95;
        if (amount > 0.0) r = drScaleChroma(clamp(r, 0.0, 1.0), 1.0 + amount * 0.25);
      }
      return float4(drDec(clamp(r, 0.0, 1.0)), o4.a);
    }

    // ---- Clipping warning ----
    [[ stitchable ]] float4 drClip(coreimage::sample_t s) {
      float3 c = s.rgb;
      if (max(c.r, max(c.g, c.b)) >= 0.995) return float4(1.0, 0.0, 0.0, s.a);
      if (max(c.r, max(c.g, c.b)) <= 0.0005) return float4(0.0, 0.25, 1.0, s.a);
      return s;
    }

    // ---- Grain noise (integer hash, same as LumaGrader) ----
    inline float drHash(int2 p) {
      uint h = uint(p.x) * 374761393u + uint(p.y) * 668265263u + 1013904223u;
      h = (h ^ (h >> 13u)) * 1274126177u;
      h = h ^ (h >> 16u);
      return float(h & 0xffffffu) / 16777215.0;
    }

    inline float drValueNoise(float2 p) {
      float2 i = floor(p);
      float2 f = p - i;
      f = f * f * (3.0 - 2.0 * f);
      int2 q = int2(i);
      float a = drHash(q), b = drHash(q + int2(1, 0)), c = drHash(q + int2(0, 1)), d = drHash(q + int2(1, 1));
      return a + (b - a) * f.x + (c - a) * f.y + (a - b - c + d) * f.x * f.y;
    }

    // ---- Post-crop vignette + grain ----
    // vig = (amount, midpoint, roundness, feather); grain = (amplitude, cellsX, cellsY, roughness);
    // frame = (x, y, width, height) of the final image.
    [[ stitchable ]] float4 drFinish(coreimage::sample_t s, float4 vig, float vigHighlights,
                                     float4 grain, float4 frame, coreimage::destination dest) {
      float3 c = drEnc(clamp(s.rgb, 0.0, 1.0));
      float2 pos = dest.coord();
      float u = (pos.x - frame.x) / frame.z;
      float v = 1.0 - (pos.y - frame.y) / frame.w;
      if (vig.x != 0.0) {
        float x = (u - 0.5) * 2.0;
        float y = (v - 0.5) * 2.0;
        if (vig.z > 0.0) {
          float m = min(frame.z, frame.w);
          x *= 1.0 + (frame.z / m - 1.0) * vig.z;
          y *= 1.0 + (frame.w / m - 1.0) * vig.z;
        }
        float p = vig.z < 0.0 ? 2.0 - vig.z * 4.0 : 2.0;
        float d = pow(pow(abs(x), p) + pow(abs(y), p), 1.0 / p);
        float r = 0.45 + 0.95 * vig.y;
        float fw = 0.05 + vig.w;
        float wgt = drSmooth(r - fw / 2.0, r + fw / 2.0, d);
        if (vig.x < 0.0) {
          float k = -vig.x * wgt;
          if (vigHighlights > 0.0) k *= 1.0 - 0.9 * vigHighlights * drSmooth(0.5, 1.0, drLuma(c));
          c *= 1.0 - 0.85 * k;
        } else {
          c = mix(c, float3(1.0), vig.x * wgt * 0.85);
        }
      }
      if (grain.x > 0.0) {
        float2 gp = float2(u * grain.y, v * grain.z);
        float n = (1.0 - 0.6 * grain.w) * (drValueNoise(gp) - 0.5)
                + 0.6 * grain.w * (drValueNoise(gp * 2.3 + float2(17.1, 5.3)) - 0.5);
        float le = drLuma(c);
        c += n * 2.0 * grain.x * (0.3 + 0.7 * 4.0 * le * (1.0 - le));
      }
      return float4(drDec(clamp(c, 0.0, 1.0)), s.a);
    }
    """
}
