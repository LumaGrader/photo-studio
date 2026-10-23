import Foundation

/// One Color Grading wheel: Hue 0–360, Saturation 0–100, Luminance -100…100.
struct GradeWheel: Codable, Hashable {
    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0

    var isNeutral: Bool { saturation == 0 && luminance == 0 }
}

/// Lightroom-style Color Grading: three tonal wheels + Global, Blending, Balance.
struct ColorGrade: Codable, Hashable {
    var shadows = GradeWheel()
    var midtones = GradeWheel()
    var highlights = GradeWheel()
    var global = GradeWheel()
    var blending: Double = 50   // 0…100
    var balance: Double = 0     // -100…100

    var isActive: Bool {
        !(shadows.isNeutral && midtones.isNeutral && highlights.isNeutral && global.isNeutral)
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case shadows, midtones, highlights, global, blending, balance
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shadows = try c.decodeIfPresent(GradeWheel.self, forKey: .shadows) ?? GradeWheel()
        midtones = try c.decodeIfPresent(GradeWheel.self, forKey: .midtones) ?? GradeWheel()
        highlights = try c.decodeIfPresent(GradeWheel.self, forKey: .highlights) ?? GradeWheel()
        global = try c.decodeIfPresent(GradeWheel.self, forKey: .global) ?? GradeWheel()
        blending = try c.decodeIfPresent(Double.self, forKey: .blending) ?? 50
        balance = try c.decodeIfPresent(Double.self, forKey: .balance) ?? 0
    }
}

/// Profile: the base rendering (RAW: macOS decode + Darkroom Color, or the decode as is)
/// plus Darkroom's own looks on top. These are Darkroom looks in the spirit of the usual
/// camera profiles (Standard, Vivid…), not copies of any camera maker's or Adobe's profiles.
enum RawProfile: String, Codable, CaseIterable, Identifiable {
    /// macOS RAW decode + a look calibrated to Lightroom's Adobe Color (default).
    case darkroomColor = "Darkroom Color"
    /// Matches Lightroom's Adobe Standard / Camera Standard base rendering (RAW only).
    case adobeStandard = "Adobe Standard"
    case cameraStandard = "Camera Standard"
    case standard = "Darkroom Standard"
    case vivid = "Darkroom Vivid"
    case portrait = "Darkroom Portrait"
    case landscape = "Darkroom Landscape"
    case neutral = "Darkroom Neutral"
    case monochrome = "Darkroom Monochrome"
    /// macOS RAW decode as is (RAW only).
    case cameraNeutral = "Camera Neutral"

    var id: String { rawValue }

    /// Short name for menus.
    var shortName: String { rawValue.replacingOccurrences(of: "Darkroom ", with: "") }

    /// Looks drawn on top of the base (everything except Color and Camera Neutral).
    var isLook: Bool { !isBase }

    /// Base renderings (not looks drawn on top of Color).
    var isBase: Bool { [.darkroomColor, .adobeStandard, .cameraStandard, .cameraNeutral].contains(self) }

    /// Only meaningful for RAW files.
    var isRawOnly: Bool { [.adobeStandard, .cameraStandard, .cameraNeutral].contains(self) }
}

/// Non-destructive edits for one photo, stored as JSON in the catalog.
/// Slider values are Lightroom-style: -100...100 unless noted.
struct DevelopSettings: Codable, Hashable {
    static let hslBandCount = 8
    /// Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta.
    static let hslBandNames = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]

    var exposure: Double = 0     // EV, -5...5
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    /// RAW: Kelvin, nil = As Shot. Other files: -100...100 (nil = 0).
    var temperature: Double?
    /// RAW: -150...150, nil = As Shot. Other files: -100...100 (nil = 0).
    var tint: Double?
    var vibrance: Double = 0
    var saturation: Double = 0
    /// Color Mixer (HSL), one value per band, -100…100.
    var hslHue = [Double](repeating: 0, count: 8)
    var hslSaturation = [Double](repeating: 0, count: 8)
    var hslLuminance = [Double](repeating: 0, count: 8)
    var colorGrade = ColorGrade()
    /// Profile; nil = Darkroom Color.
    var profile: RawProfile?
    /// Imported LUT profile (file name in the Profiles folder), on top of `profile`.
    var lutProfile: String?
    /// Strength of the look / LUT profile, 0…200.
    var profileAmount: Double = 100
    var curve = ToneCurvePoints()
    var crop = CropSettings()
    var detail = DetailSettings()
    var effects = EffectsSettings()
    /// Treatment: Black & White (the Color Mixer becomes the B&W mix).
    var blackWhite = false
    /// B&W mix per colour band, -100…100.
    var bwMix = [Double](repeating: 0, count: 8)
    var pointColors: [PointColor] = []
    var calibration = CalibrationSettings()
    /// Local adjustments (Masking), applied in order.
    var masks: [MaskLayer] = []
    /// Spot Removal (Heal / Clone), applied in order.
    var spots: [SpotEdit] = []
    var lensBlur = LensBlurSettings()

    static let `default` = DevelopSettings()

    var effectiveProfile: RawProfile { profile ?? .darkroomColor }

    var isDefault: Bool { self == .default }

    var isHSLActive: Bool {
        (hslHue + hslSaturation + hslLuminance).contains { $0 != 0 }
    }

    /// Point Color entries that change something (the kernel handles up to 4).
    var activePointColors: [PointColor] {
        Array(pointColors.filter { !$0.isNeutral }.prefix(PointColor.maxCount))
    }

    /// Stable text key for caches.
    var cacheKey: String { String(describing: self) }

    init() {}

    // Missing keys fall back to defaults, so older catalogs keep loading
    // when new sliders are added.
    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, whites, blacks
        case temperature, tint, vibrance, saturation
        case hslHue, hslSaturation, hslLuminance, colorGrade, profile, lutProfile, profileAmount, curve, crop, detail, effects
        case blackWhite, bwMix, pointColors, calibration, masks, spots, lensBlur
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        whites = try c.decodeIfPresent(Double.self, forKey: .whites) ?? 0
        blacks = try c.decodeIfPresent(Double.self, forKey: .blacks) ?? 0
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        tint = try c.decodeIfPresent(Double.self, forKey: .tint)
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        hslHue = Self.bands(try c.decodeIfPresent([Double].self, forKey: .hslHue))
        hslSaturation = Self.bands(try c.decodeIfPresent([Double].self, forKey: .hslSaturation))
        hslLuminance = Self.bands(try c.decodeIfPresent([Double].self, forKey: .hslLuminance))
        colorGrade = try c.decodeIfPresent(ColorGrade.self, forKey: .colorGrade) ?? ColorGrade()
        profile = try? c.decodeIfPresent(RawProfile.self, forKey: .profile)
        lutProfile = try? c.decodeIfPresent(String.self, forKey: .lutProfile)
        profileAmount = (try? c.decodeIfPresent(Double.self, forKey: .profileAmount)) ?? 100
        curve = (try? c.decodeIfPresent(ToneCurvePoints.self, forKey: .curve)) ?? ToneCurvePoints()
        crop = (try? c.decodeIfPresent(CropSettings.self, forKey: .crop)) ?? CropSettings()
        detail = (try? c.decodeIfPresent(DetailSettings.self, forKey: .detail)) ?? DetailSettings()
        effects = (try? c.decodeIfPresent(EffectsSettings.self, forKey: .effects)) ?? EffectsSettings()
        blackWhite = (try? c.decodeIfPresent(Bool.self, forKey: .blackWhite)) ?? false
        bwMix = Self.bands(try? c.decodeIfPresent([Double].self, forKey: .bwMix))
        pointColors = (try? c.decodeIfPresent([PointColor].self, forKey: .pointColors)) ?? []
        calibration = (try? c.decodeIfPresent(CalibrationSettings.self, forKey: .calibration)) ?? CalibrationSettings()
        masks = (try? c.decodeIfPresent([MaskLayer].self, forKey: .masks)) ?? []
        spots = (try? c.decodeIfPresent([SpotEdit].self, forKey: .spots)) ?? []
        lensBlur = (try? c.decodeIfPresent(LensBlurSettings.self, forKey: .lensBlur)) ?? LensBlurSettings()
    }

    /// Exactly 8 values (pads/truncates bad data).
    private static func bands(_ values: [Double]?) -> [Double] {
        let v = values ?? []
        return (0..<hslBandCount).map { $0 < v.count ? v[$0] : 0 }
    }

    func jsonString() -> String? {
        guard !isDefault, let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func from(json: String?) -> DevelopSettings {
        guard let json, let data = json.data(using: .utf8),
              let settings = try? JSONDecoder().decode(DevelopSettings.self, from: data)
        else { return .default }
        return settings
    }
}
