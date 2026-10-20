import Foundation

// MARK: - Spot Removal

/// One Heal or Clone spot (Lightroom's Spot Removal / Healing tool).
/// Points are 0…1 of the uncropped photo from the top-left, like mask points, so spots
/// stay put when the crop changes.
struct SpotEdit: Codable, Hashable, Identifiable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        /// Copies texture from the source and blends it into the colour and light around the spot.
        case heal = "Heal"
        /// Copies the source as is.
        case clone = "Clone"
        var id: String { rawValue }
    }

    var id = UUID()
    var mode: Mode = .heal
    /// The blemish being covered.
    var center: MaskPoint
    /// Where the replacement pixels come from.
    var source: MaskPoint
    /// Radius, fraction of the photo's long side.
    var radius: Double = 0.02
    /// Soft edge, 0…100.
    var feather: Double = 50
    /// 0…100.
    var opacity: Double = 100

    init(mode: Mode, center: MaskPoint, source: MaskPoint, radius: Double, feather: Double, opacity: Double) {
        self.mode = mode
        self.center = center
        self.source = source
        self.radius = radius
        self.feather = feather
        self.opacity = opacity
    }

    private enum CodingKeys: String, CodingKey { case id, mode, center, source, radius, feather, opacity }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? .heal
        center = try c.decode(MaskPoint.self, forKey: .center)
        source = try c.decode(MaskPoint.self, forKey: .source)
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 0.02
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 50
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 100
    }
}

/// Settings for new spots (the Healing panel when no spot is selected).
struct SpotDefaults: Equatable {
    var mode: SpotEdit.Mode = .heal
    var radius = 0.02
    var feather = 50.0
    var opacity = 100.0
}

// MARK: - Lens Blur

/// Background blur with bokeh. Depth comes from the photo's own depth map (iPhone Portrait
/// photos) or, for every other photo, from Select Subject: the subject stays sharp.
struct LensBlurSettings: Codable, Hashable {
    enum Bokeh: String, Codable, CaseIterable, Identifiable {
        case circle = "Circle"
        case bubble = "Bubble"
        case soft = "Soft"
        var id: String { rawValue }
    }

    var enabled = false
    /// Blur strength, 0…100.
    var amount: Double = 50
    var bokeh: Bokeh = .circle
    /// Brightens out-of-focus highlights so they bloom into discs, 0…100.
    var boost: Double = 25
    /// Depth maps only: the distance in focus, 0 = nearest … 100 = farthest.
    var focus: Double = 0
    /// Depth maps only: how deep the sharp zone is, 0…100.
    var focusRange: Double = 20
    /// Softness of the edge between sharp and blurred, 0…100.
    var edge: Double = 30

    var isActive: Bool { enabled && amount > 0 }

    init() {}

    private enum CodingKeys: String, CodingKey { case enabled, amount, bokeh, boost, focus, focusRange, edge }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 50
        bokeh = (try? c.decodeIfPresent(Bokeh.self, forKey: .bokeh)) ?? .circle
        boost = try c.decodeIfPresent(Double.self, forKey: .boost) ?? 25
        focus = try c.decodeIfPresent(Double.self, forKey: .focus) ?? 0
        focusRange = try c.decodeIfPresent(Double.self, forKey: .focusRange) ?? 20
        edge = try c.decodeIfPresent(Double.self, forKey: .edge) ?? 30
    }
}
