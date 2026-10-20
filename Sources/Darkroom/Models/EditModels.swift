import Foundation

// MARK: - Crop & straighten

/// Geometry applied after all colour/tone edits, in this order:
/// 90° rotation → straighten (fine angle) → crop.
/// The crop rectangle is normalised to the rotated frame (0…1, y from the top) and always
/// stays inside the straightened photo (no empty corners), like Lightroom.
struct CropSettings: Codable, Hashable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 1
    var height: Double = 1
    /// Straighten, degrees, -45…45 (positive turns the photo clockwise).
    var angle: Double = 0
    /// Quarter turns clockwise: 0, 90, 180, 270.
    var rotate90: Int = 0

    var isDefault: Bool { self == CropSettings() }

    init() {}

    private enum CodingKeys: String, CodingKey { case x, y, width, height, angle, rotate90 }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 1
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 1
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0
        rotate90 = try c.decodeIfPresent(Int.self, forKey: .rotate90) ?? 0
    }

    /// Frame size after the 90° rotation.
    func frameSize(for size: CGSize) -> CGSize {
        rotate90 % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    /// A quarter turn, with the crop rectangle turned along (Rotate Left / Right in the Library).
    func rotated(clockwise: Bool) -> CropSettings {
        var c = self
        c.rotate90 = ((rotate90 + (clockwise ? 90 : -90)) % 360 + 360) % 360
        c.width = height
        c.height = width
        if clockwise {
            c.x = 1 - y - height
            c.y = x
        } else {
            c.x = y
            c.y = 1 - x - width
        }
        return c
    }
}

/// Keeps a crop rectangle inside the straightened photo.
enum CropGeometry {
    /// True when the normalised point (y from the top) lies on the photo after straightening.
    static func isInside(_ u: Double, _ v: Double, angle: Double, frame: CGSize) -> Bool {
        let w = Double(frame.width), h = Double(frame.height)
        let px = (u - 0.5) * w
        let py = (0.5 - v) * h
        let a = angle * .pi / 180  // photo turned clockwise by `angle` → undo by turning CCW
        let rx = px * cos(a) - py * sin(a)
        let ry = px * sin(a) + py * cos(a)
        return abs(rx) <= w / 2 + 1e-6 && abs(ry) <= h / 2 + 1e-6
    }

    static func fits(_ c: CropSettings, frame: CGSize) -> Bool {
        guard c.x >= -1e-9, c.y >= -1e-9, c.x + c.width <= 1 + 1e-9, c.y + c.height <= 1 + 1e-9 else { return false }
        for (u, v) in [(c.x, c.y), (c.x + c.width, c.y), (c.x, c.y + c.height), (c.x + c.width, c.y + c.height)] {
            if !isInside(u, v, angle: c.angle, frame: frame) { return false }
        }
        return true
    }

    /// Shrinks the rectangle around its centre (keeping its shape) until it fits.
    static func fitted(_ crop: CropSettings, frame: CGSize) -> CropSettings {
        var c = crop
        c.width = min(max(c.width, 0.02), 1)
        c.height = min(max(c.height, 0.02), 1)
        c.x = min(max(c.x, 0), 1 - c.width)
        c.y = min(max(c.y, 0), 1 - c.height)
        if fits(c, frame: frame) { return c }
        let cx = c.x + c.width / 2, cy = c.y + c.height / 2
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let s = (lo + hi) / 2
            var t = c
            t.width = c.width * s
            t.height = c.height * s
            t.x = cx - t.width / 2
            t.y = cy - t.height / 2
            if fits(t, frame: frame) { lo = s } else { hi = s }
        }
        var result = c
        result.width = c.width * lo
        result.height = c.height * lo
        result.x = cx - result.width / 2
        result.y = cy - result.height / 2
        return result
    }

    /// Largest rectangle of `ratio` (width ÷ height in pixels) centred in the frame.
    static func centred(ratio: Double, angle: Double, rotate90: Int, frame: CGSize) -> CropSettings {
        var c = CropSettings()
        c.angle = angle
        c.rotate90 = rotate90
        let frameRatio = Double(frame.width / frame.height)
        if ratio > frameRatio {
            c.width = 1
            c.height = frameRatio / ratio
        } else {
            c.height = 1
            c.width = ratio / frameRatio
        }
        c.x = (1 - c.width) / 2
        c.y = (1 - c.height) / 2
        return fitted(c, frame: frame)
    }
}

// MARK: - Point tone curve

struct CurvePoint: Codable, Hashable {
    var x: Double  // 0…255
    var y: Double  // 0…255
}

/// Lightroom-style point curves: RGB (all channels) plus Red, Green, Blue.
struct ToneCurvePoints: Codable, Hashable {
    static let identity = [CurvePoint(x: 0, y: 0), CurvePoint(x: 255, y: 255)]

    var rgb = ToneCurvePoints.identity
    var red = ToneCurvePoints.identity
    var green = ToneCurvePoints.identity
    var blue = ToneCurvePoints.identity
    /// Region (parametric) curve, applied before the point curves.
    var parametric = ParametricCurve()

    var isIdentity: Bool { [rgb, red, green, blue].allSatisfy(Self.isIdentity) && parametric.isNeutral }

    static func isIdentity(_ points: [CurvePoint]) -> Bool {
        points.count < 2 || points.allSatisfy { $0.x == $0.y } && points.first?.x == 0 && points.last?.x == 255
    }

    init() {}

    private enum CodingKeys: String, CodingKey { case rgb, red, green, blue, parametric }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rgb = try c.decodeIfPresent([CurvePoint].self, forKey: .rgb) ?? Self.identity
        red = try c.decodeIfPresent([CurvePoint].self, forKey: .red) ?? Self.identity
        green = try c.decodeIfPresent([CurvePoint].self, forKey: .green) ?? Self.identity
        blue = try c.decodeIfPresent([CurvePoint].self, forKey: .blue) ?? Self.identity
        parametric = (try? c.decodeIfPresent(ParametricCurve.self, forKey: .parametric)) ?? ParametricCurve()
    }
}

/// Lightroom-style region curve: Highlights, Lights, Darks, Shadows (−100…100) with
/// three movable splits (0…100).
struct ParametricCurve: Codable, Hashable {
    var highlights: Double = 0
    var lights: Double = 0
    var darks: Double = 0
    var shadows: Double = 0
    var shadowSplit: Double = 25
    var midtoneSplit: Double = 50
    var highlightSplit: Double = 75

    var isNeutral: Bool { highlights == 0 && lights == 0 && darks == 0 && shadows == 0 }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case highlights, lights, darks, shadows, shadowSplit, midtoneSplit, highlightSplit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        lights = try c.decodeIfPresent(Double.self, forKey: .lights) ?? 0
        darks = try c.decodeIfPresent(Double.self, forKey: .darks) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        shadowSplit = try c.decodeIfPresent(Double.self, forKey: .shadowSplit) ?? 25
        midtoneSplit = try c.decodeIfPresent(Double.self, forKey: .midtoneSplit) ?? 50
        highlightSplit = try c.decodeIfPresent(Double.self, forKey: .highlightSplit) ?? 75
    }

    /// Maps 0…1 → 0…1. Each region pushes its part of the tonal range up or down with a
    /// smooth bump peaking in the middle of the region; black and white stay put.
    func value(at x: Double) -> Double {
        guard !isNeutral else { return x }
        let s1 = min(max(shadowSplit, 5), 95) / 100
        let s2 = min(max(midtoneSplit, s1 * 100 + 1), 96) / 100
        let s3 = min(max(highlightSplit, s2 * 100 + 1), 97) / 100
        let centres = [s1 / 2, (s1 + s2) / 2, (s2 + s3) / 2, (s3 + 1) / 2]
        let amounts = [shadows, darks, lights, highlights].map { $0 / 100 }
        func smooth(_ a: Double, _ b: Double, _ v: Double) -> Double {
            let t = min(max((v - a) / max(b - a, 1e-6), 0), 1)
            return t * t * (3 - 2 * t)
        }
        var delta = 0.0
        for i in 0..<4 where amounts[i] != 0 {
            let left = i == 0 ? 0 : centres[i - 1]
            let right = i == 3 ? 1 : centres[i + 1]
            let hat = x < centres[i] ? smooth(left, centres[i], x) : 1 - smooth(centres[i], right, x)
            delta += amounts[i] * 0.22 * hat
        }
        let envelope = (4 * x * (1 - x)).squareRoot()
        return min(1, max(0, x + delta * envelope))
    }
}

/// Smooth curve through the points (C2 cubic spline, modelled on the solver Camera Raw
/// uses for point curves; ported from lumagrader src/engine/curvePoints.js).
/// Flat outside the first/last point; output clamped to 0…255.
struct CurveSpline {
    private let xs: [Double]
    private let ys: [Double]
    private let slopes: [Double]

    init(_ points: [CurvePoint]) {
        let ordered = points.sorted { $0.x < $1.x }
        var unique: [CurvePoint] = []
        for point in ordered where unique.last?.x != point.x {
            unique.append(point)
        }
        if unique.count < 2 { unique = ToneCurvePoints.identity }
        xs = unique.map(\.x)
        ys = unique.map(\.y)
        slopes = CurveSpline.solve(xs, ys)
    }

    func value(at x: Double) -> Double {
        let last = xs.count - 1
        if x <= xs[0] { return ys[0] }
        if x >= xs[last] { return ys[last] }
        var j = 0
        while j < last - 1 && x > xs[j + 1] { j += 1 }
        let h = xs[j + 1] - xs[j]
        let t = (x - xs[j]) / h
        let t2 = t * t, t3 = t2 * t
        let y = (2 * t3 - 3 * t2 + 1) * ys[j] + (t3 - 2 * t2 + t) * h * slopes[j]
            + (-2 * t3 + 3 * t2) * ys[j + 1] + (t3 - t2) * h * slopes[j + 1]
        return min(255, max(0, y))
    }

    private static func solve(_ x: [Double], _ y: [Double]) -> [Double] {
        let n = x.count
        var s = [Double](repeating: 0, count: n)
        var a = x[1] - x[0]
        var b = (y[1] - y[0]) / a
        s[0] = b
        if n > 2 {
            for j in 2..<n {
                let c = x[j] - x[j - 1]
                let d = (y[j] - y[j - 1]) / c
                s[j - 1] = (b * c + d * a) / (a + c)
                a = c
                b = d
            }
        }
        s[n - 1] = 2 * b - s[n - 2]
        s[0] = 2 * s[0] - s[1]
        if n > 2 {
            var e = [Double](repeating: 0, count: n)
            var f = [Double](repeating: 0, count: n)
            var g = [Double](repeating: 0, count: n)
            f[0] = 0.5
            e[n - 1] = 0.5
            g[0] = 0.75 * (s[0] + s[1])
            g[n - 1] = 0.75 * (s[n - 2] + s[n - 1])
            for j in 1..<(n - 1) {
                let span = (x[j + 1] - x[j - 1]) * 2
                e[j] = (x[j + 1] - x[j]) / span
                f[j] = (x[j] - x[j - 1]) / span
                g[j] = 1.5 * s[j]
            }
            for j in 1..<n {
                let pivot = 1 - f[j - 1] * e[j]
                if j != n - 1 { f[j] /= pivot }
                g[j] = (g[j] - g[j - 1] * e[j]) / pivot
            }
            for j in stride(from: n - 2, through: 0, by: -1) { g[j] -= f[j] * g[j + 1] }
            s = g
        }
        return s
    }
}

// MARK: - Groups (copy/paste, presets)

enum SettingsGroup: String, CaseIterable, Codable, Identifiable {
    case profile = "Profile"
    case whiteBalance = "White Balance"
    case tone = "Tone"
    case presence = "Presence"
    case toneCurve = "Tone Curve"
    case colorMixer = "Color Mixer"
    case colorGrading = "Color Grading"
    case calibration = "Calibration"
    case masks = "Masks"
    case detail = "Detail"
    case effects = "Effects"
    case crop = "Crop & Straighten"
    case spotRemoval = "Spot Removal"
    case lensBlur = "Lens Blur"

    var id: String { rawValue }

    /// Everything except crop, masks and spots (they rarely fit another photo).
    static let defaultSelection: Set<SettingsGroup> =
        Set(allCases.filter { $0 != .crop && $0 != .masks && $0 != .spotRemoval })
}

extension DevelopSettings {
    /// The setting groups that differ between these settings and `other` (Auto Sync).
    func changedGroups(comparedTo other: DevelopSettings) -> Set<SettingsGroup> {
        Set(SettingsGroup.allCases.filter { merging(other, groups: [$0]) != self })
    }

    /// Returns these settings with the chosen groups taken from `source`.
    func merging(_ source: DevelopSettings, groups: Set<SettingsGroup>) -> DevelopSettings {
        var s = self
        for group in groups {
            switch group {
            case .profile:
                s.profile = source.profile
                s.lutProfile = source.lutProfile
                s.profileAmount = source.profileAmount
            case .whiteBalance:
                s.temperature = source.temperature
                s.tint = source.tint
            case .tone:
                s.exposure = source.exposure
                s.contrast = source.contrast
                s.highlights = source.highlights
                s.shadows = source.shadows
                s.whites = source.whites
                s.blacks = source.blacks
            case .presence:
                s.vibrance = source.vibrance
                s.saturation = source.saturation
                s.effects.texture = source.effects.texture
                s.effects.clarity = source.effects.clarity
                s.effects.dehaze = source.effects.dehaze
            case .toneCurve:
                s.curve = source.curve
            case .colorMixer:
                s.hslHue = source.hslHue
                s.hslSaturation = source.hslSaturation
                s.hslLuminance = source.hslLuminance
                s.blackWhite = source.blackWhite
                s.bwMix = source.bwMix
                s.pointColors = source.pointColors
            case .calibration:
                s.calibration = source.calibration
            case .colorGrading:
                s.colorGrade = source.colorGrade
            case .detail:
                s.detail = source.detail
            case .effects:
                // Vignette + grain (Texture/Clarity/Dehaze belong to Presence, like Lightroom).
                var effects = source.effects
                effects.texture = s.effects.texture
                effects.clarity = s.effects.clarity
                effects.dehaze = s.effects.dehaze
                s.effects = effects
            case .crop:
                s.crop = source.crop
            case .masks:
                s.masks = source.masks
            case .spotRemoval:
                s.spots = source.spots
            case .lensBlur:
                s.lensBlur = source.lensBlur
            }
        }
        return s
    }
}

struct DevelopPreset: Identifiable, Hashable {
    let id: Int64
    var name: String
    var settings: DevelopSettings
    var groups: Set<SettingsGroup>
}

// MARK: - Detail

/// Sharpening, noise reduction and lens corrections (Lightroom's Detail + Lens panels).
/// nil = the default for the file type (RAW: sharpening 40, colour NR 25, lens profile on;
/// JPEG and other files: all off), like Lightroom.
struct DetailSettings: Codable, Hashable {
    var sharpening: Double?          // 0…150
    var noiseReduction: Double = 0   // luminance, 0…100
    var colorNoiseReduction: Double? // 0…100
    var lensCorrections: Bool?
    /// Darkroom Denoise (GPU, edge-aware), 0 = off … 100.
    var denoise: Double = 0
    /// How much fine texture Denoise keeps, 0…100.
    var denoiseDetail: Double = 50

    static let rawSharpening = 40.0
    static let rawColorNoise = 25.0

    func effectiveSharpening(isRaw: Bool) -> Double { sharpening ?? (isRaw ? Self.rawSharpening : 0) }
    func colorNoise(isRaw: Bool) -> Double { colorNoiseReduction ?? (isRaw ? Self.rawColorNoise : 0) }
    func lensOn(isRaw: Bool) -> Bool { lensCorrections ?? isRaw }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case sharpening, noiseReduction, colorNoiseReduction, lensCorrections, denoise, denoiseDetail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sharpening = try c.decodeIfPresent(Double.self, forKey: .sharpening)
        noiseReduction = try c.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? 0
        colorNoiseReduction = try c.decodeIfPresent(Double.self, forKey: .colorNoiseReduction)
        lensCorrections = try c.decodeIfPresent(Bool.self, forKey: .lensCorrections)
        denoise = try c.decodeIfPresent(Double.self, forKey: .denoise) ?? 0
        denoiseDetail = try c.decodeIfPresent(Double.self, forKey: .denoiseDetail) ?? 50
    }
}

// MARK: - Effects

/// Texture, Clarity, Dehaze (Presence) and post-crop Vignette + Grain (Effects).
struct EffectsSettings: Codable, Hashable {
    var texture: Double = 0             // -100…100
    var clarity: Double = 0             // -100…100
    var dehaze: Double = 0              // -100…100
    var vignette: Double = 0            // -100…100 (negative darkens corners)
    var vignetteMidpoint: Double = 50   // 0…100
    var vignetteRoundness: Double = 0   // -100…100
    var vignetteFeather: Double = 50    // 0…100
    var vignetteHighlights: Double = 0  // 0…100
    var grain: Double = 0               // 0…100
    var grainSize: Double = 25          // 0…100
    var grainRoughness: Double = 50     // 0…100

    var presenceActive: Bool { texture != 0 || clarity != 0 || dehaze != 0 }
    var finishActive: Bool { vignette != 0 || grain != 0 }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case texture, clarity, dehaze, vignette, vignetteMidpoint, vignetteRoundness
        case vignetteFeather, vignetteHighlights, grain, grainSize, grainRoughness
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys, _ fallback: Double) throws -> Double {
            try c.decodeIfPresent(Double.self, forKey: key) ?? fallback
        }
        texture = try value(.texture, 0)
        clarity = try value(.clarity, 0)
        dehaze = try value(.dehaze, 0)
        vignette = try value(.vignette, 0)
        vignetteMidpoint = try value(.vignetteMidpoint, 50)
        vignetteRoundness = try value(.vignetteRoundness, 0)
        vignetteFeather = try value(.vignetteFeather, 50)
        vignetteHighlights = try value(.vignetteHighlights, 0)
        grain = try value(.grain, 0)
        grainSize = try value(.grainSize, 25)
        grainRoughness = try value(.grainRoughness, 50)
    }
}

// MARK: - Point Color

/// A colour picked from the photo (Oklab L, chroma, hue) and how to change it.
struct PointColor: Codable, Hashable, Identifiable {
    var id = UUID()
    var lightness: Double       // Oklab L, 0…1
    var chroma: Double          // Oklab chroma
    var hue: Double             // degrees
    var hueShift: Double = 0    // -100…100
    var saturationShift: Double = 0
    var luminanceShift: Double = 0
    var range: Double = 50      // 0…100

    static let maxCount = 4

    var isNeutral: Bool { hueShift == 0 && saturationShift == 0 && luminanceShift == 0 }

    init(lightness: Double, chroma: Double, hue: Double) {
        self.lightness = lightness
        self.chroma = chroma
        self.hue = hue
    }

    private enum CodingKeys: String, CodingKey {
        case id, lightness, chroma, hue, hueShift, saturationShift, luminanceShift, range
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        lightness = try c.decodeIfPresent(Double.self, forKey: .lightness) ?? 0.5
        chroma = try c.decodeIfPresent(Double.self, forKey: .chroma) ?? 0.1
        hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0
        hueShift = try c.decodeIfPresent(Double.self, forKey: .hueShift) ?? 0
        saturationShift = try c.decodeIfPresent(Double.self, forKey: .saturationShift) ?? 0
        luminanceShift = try c.decodeIfPresent(Double.self, forKey: .luminanceShift) ?? 0
        range = try c.decodeIfPresent(Double.self, forKey: .range) ?? 50
    }
}

// MARK: - Calibration

/// Lightroom's Calibration panel: moves the red, green and blue primaries (−100…100).
struct CalibrationSettings: Codable, Hashable {
    var redHue: Double = 0
    var redSaturation: Double = 0
    var greenHue: Double = 0
    var greenSaturation: Double = 0
    var blueHue: Double = 0
    var blueSaturation: Double = 0

    var isNeutral: Bool { self == CalibrationSettings() }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case redHue, redSaturation, greenHue, greenSaturation, blueHue, blueSaturation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        redHue = try c.decodeIfPresent(Double.self, forKey: .redHue) ?? 0
        redSaturation = try c.decodeIfPresent(Double.self, forKey: .redSaturation) ?? 0
        greenHue = try c.decodeIfPresent(Double.self, forKey: .greenHue) ?? 0
        greenSaturation = try c.decodeIfPresent(Double.self, forKey: .greenSaturation) ?? 0
        blueHue = try c.decodeIfPresent(Double.self, forKey: .blueHue) ?? 0
        blueSaturation = try c.decodeIfPresent(Double.self, forKey: .blueSaturation) ?? 0
    }
}

// MARK: - Preset Amount

extension DevelopSettings {
    /// Lightroom-style preset Amount: every value the preset sets is scaled from the
    /// default (0 % = no change, 100 % = the preset, 200 % = twice as strong).
    /// Kelvin white balance, crop and choices (profile, B&W) are kept as they are.
    func scaledPreset(_ t: Double) -> DevelopSettings {
        guard abs(t - 1) > 0.001 else { return self }
        func f(_ base: Double, _ value: Double, _ lo: Double = -100, _ hi: Double = 100) -> Double {
            min(max(base + (value - base) * t, lo), hi)
        }
        var s = self
        s.exposure = f(0, exposure, -5, 5)
        s.contrast = f(0, contrast)
        s.highlights = f(0, highlights)
        s.shadows = f(0, shadows)
        s.whites = f(0, whites)
        s.blacks = f(0, blacks)
        s.vibrance = f(0, vibrance)
        s.saturation = f(0, saturation)
        // Relative white balance (non-RAW presets) scales; Kelvin can't scale without the photo.
        if let temperature, temperature <= 100 {
            s.temperature = f(0, temperature)
            s.tint = tint.map { f(0, $0) }
        }
        s.hslHue = hslHue.map { f(0, $0) }
        s.hslSaturation = hslSaturation.map { f(0, $0) }
        s.hslLuminance = hslLuminance.map { f(0, $0) }
        s.bwMix = bwMix.map { f(0, $0) }
        for path in [\ColorGrade.shadows, \ColorGrade.midtones, \ColorGrade.highlights, \ColorGrade.global] {
            s.colorGrade[keyPath: path].saturation = f(0, colorGrade[keyPath: path].saturation, 0, 100)
            s.colorGrade[keyPath: path].luminance = f(0, colorGrade[keyPath: path].luminance)
        }
        s.colorGrade.balance = f(0, colorGrade.balance)
        // Point curves: scale each point's distance from the straight line.
        func scaledCurve(_ points: [CurvePoint]) -> [CurvePoint] {
            points.map { CurvePoint(x: $0.x, y: min(max($0.x + ($0.y - $0.x) * t, 0), 255)) }
        }
        s.curve.rgb = scaledCurve(curve.rgb)
        s.curve.red = scaledCurve(curve.red)
        s.curve.green = scaledCurve(curve.green)
        s.curve.blue = scaledCurve(curve.blue)
        s.curve.parametric.highlights = f(0, curve.parametric.highlights)
        s.curve.parametric.lights = f(0, curve.parametric.lights)
        s.curve.parametric.darks = f(0, curve.parametric.darks)
        s.curve.parametric.shadows = f(0, curve.parametric.shadows)
        s.effects.texture = f(0, effects.texture)
        s.effects.clarity = f(0, effects.clarity)
        s.effects.dehaze = f(0, effects.dehaze)
        s.effects.vignette = f(0, effects.vignette)
        s.effects.grain = f(0, effects.grain, 0, 100)
        s.detail.noiseReduction = f(0, detail.noiseReduction, 0, 100)
        s.calibration.redHue = f(0, calibration.redHue)
        s.calibration.redSaturation = f(0, calibration.redSaturation)
        s.calibration.greenHue = f(0, calibration.greenHue)
        s.calibration.greenSaturation = f(0, calibration.greenSaturation)
        s.calibration.blueHue = f(0, calibration.blueHue)
        s.calibration.blueSaturation = f(0, calibration.blueSaturation)
        s.pointColors = pointColors.map { p in
            var q = p
            q.hueShift = f(0, p.hueShift)
            q.saturationShift = f(0, p.saturationShift)
            q.luminanceShift = f(0, p.luminanceShift)
            return q
        }
        s.profileAmount = f(0, profileAmount, 0, 200)
        return s
    }

    /// Applies a preset at an Amount (1 = as saved).
    func applying(_ preset: DevelopSettings, groups: Set<SettingsGroup>, amount: Double) -> DevelopSettings {
        merging(preset.scaledPreset(amount), groups: groups)
    }
}

// MARK: - History labels

extension DevelopSettings {
    /// Short name for what changed between two states ("Exposure +0.50", "Tone Curve", …).
    static func changeLabel(from old: DevelopSettings, to new: DevelopSettings) -> String {
        let sliders: [(String, KeyPath<DevelopSettings, Double>, String)] = [
            ("Exposure", \.exposure, "%+.2f"), ("Contrast", \.contrast, "%+.0f"),
            ("Highlights", \.highlights, "%+.0f"), ("Shadows", \.shadows, "%+.0f"),
            ("Whites", \.whites, "%+.0f"), ("Blacks", \.blacks, "%+.0f"),
            ("Texture", \.effects.texture, "%+.0f"), ("Clarity", \.effects.clarity, "%+.0f"),
            ("Dehaze", \.effects.dehaze, "%+.0f"), ("Vibrance", \.vibrance, "%+.0f"),
            ("Saturation", \.saturation, "%+.0f"), ("Profile Amount", \.profileAmount, "%.0f"),
        ]
        var changes: [String] = []
        for (name, path, format) in sliders where old[keyPath: path] != new[keyPath: path] {
            changes.append("\(name) \(String(format: format, new[keyPath: path]))")
        }
        func group(_ name: String, _ changed: Bool) { if changed { changes.append(name) } }
        group("White Balance", old.temperature != new.temperature || old.tint != new.tint)
        group("Profile", old.profile != new.profile || old.lutProfile != new.lutProfile)
        group("Treatment", old.blackWhite != new.blackWhite)
        group("Tone Curve", old.curve != new.curve)
        group("Color Mixer", old.hslHue != new.hslHue || old.hslSaturation != new.hslSaturation
              || old.hslLuminance != new.hslLuminance || old.bwMix != new.bwMix)
        group("Point Color", old.pointColors != new.pointColors)
        group("Color Grading", old.colorGrade != new.colorGrade)
        group("Detail", old.detail != new.detail)
        group("Effects", old.effects.vignette != new.effects.vignette || old.effects.grain != new.effects.grain
              || old.effects.vignetteMidpoint != new.effects.vignetteMidpoint
              || old.effects.vignetteFeather != new.effects.vignetteFeather
              || old.effects.vignetteRoundness != new.effects.vignetteRoundness
              || old.effects.vignetteHighlights != new.effects.vignetteHighlights
              || old.effects.grainSize != new.effects.grainSize || old.effects.grainRoughness != new.effects.grainRoughness)
        group("Calibration", old.calibration != new.calibration)
        group("Crop", old.crop != new.crop)
        group("Masks", old.masks != new.masks)
        group("Spot Removal", old.spots != new.spots)
        group("Lens Blur", old.lensBlur != new.lensBlur)
        if new.isDefault && !old.isDefault { return "Reset" }
        switch changes.count {
        case 0: return "Edit"
        case 1: return changes[0]
        case 2: return changes.joined(separator: ", ")
        default: return "\(changes.count) settings"
        }
    }
}
