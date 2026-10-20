import Foundation
import CoreGraphics

// Masks (local adjustments), like Lightroom's Masking panel.
//
// Coordinates are normalised to the developed photo BEFORE crop and straighten
// (0…1, origin top-left), so masks stay on the same spot when the crop changes.
// Sizes (brush radius, radial radii) are fractions of the photo's long side.

struct MaskPoint: Codable, Hashable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    init(_ p: CGPoint) {
        x = Double(p.x)
        y = Double(p.y)
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

enum MaskKind: String, Codable, CaseIterable, Identifiable {
    case subject = "Subject"
    case brush = "Brush"
    case linear = "Linear Gradient"
    case radial = "Radial Gradient"
    case luminanceRange = "Luminance Range"
    case colorRange = "Color Range"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .subject: return "person.crop.rectangle"
        case .brush: return "paintbrush.pointed"
        case .linear: return "rectangle.bottomhalf.filled"
        case .radial: return "circle.dashed"
        case .luminanceRange: return "sun.max"
        case .colorRange: return "eyedropper"
        }
    }

    /// Kinds you edit by clicking and dragging on the photo.
    var isDrawn: Bool { self == .brush || self == .linear || self == .radial }
}

/// How a component combines with the components above it.
enum MaskMode: String, Codable, CaseIterable, Identifiable {
    case add = "Add"
    case subtract = "Subtract"
    case intersect = "Intersect"

    var id: String { rawValue }
}

struct BrushStroke: Codable, Hashable {
    var points: [MaskPoint] = []
    /// Radius, fraction of the long side.
    var radius: Double = 0.04
    /// 0…1 (soft edge share of the radius).
    var feather: Double = 0.6
    /// 0…1 (how much each dab adds).
    var flow: Double = 0.8
    var erase = false
}

struct MaskComponent: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: MaskKind
    var mode: MaskMode = .add
    var invert = false

    // Linear gradient: full effect at `start`, none past `end`.
    var start = MaskPoint(0.5, 0.25)
    var end = MaskPoint(0.5, 0.55)

    // Radial gradient (ellipse).
    var center = MaskPoint(0.5, 0.5)
    var radiusX = 0.2
    var radiusY = 0.15
    /// Degrees, clockwise on screen.
    var angle = 0.0
    /// 0…100.
    var feather = 50.0

    // Brush.
    var strokes: [BrushStroke] = []

    // Luminance range, 0…1.
    var lumLow = 0.5
    var lumHigh = 1.0
    var lumSmoothness = 0.15

    // Color range: picked colour (Oklab) and how wide the match is (0…100).
    var pickL = 0.6
    var pickA = 0.0
    var pickB = 0.0
    var colorAmount = 50.0
    var hasPickedColor = false

    init(kind: MaskKind, mode: MaskMode = .add) {
        self.kind = kind
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, mode, invert, start, end, center, radiusX, radiusY, angle, feather, strokes
        case lumLow, lumHigh, lumSmoothness, pickL, pickA, pickB, colorAmount, hasPickedColor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? c.decodeIfPresent(MaskKind.self, forKey: .kind)) ?? .brush
        mode = (try? c.decodeIfPresent(MaskMode.self, forKey: .mode)) ?? .add
        invert = (try? c.decodeIfPresent(Bool.self, forKey: .invert)) ?? false
        start = (try? c.decodeIfPresent(MaskPoint.self, forKey: .start)) ?? MaskPoint(0.5, 0.25)
        end = (try? c.decodeIfPresent(MaskPoint.self, forKey: .end)) ?? MaskPoint(0.5, 0.55)
        center = (try? c.decodeIfPresent(MaskPoint.self, forKey: .center)) ?? MaskPoint(0.5, 0.5)
        radiusX = (try? c.decodeIfPresent(Double.self, forKey: .radiusX)) ?? 0.2
        radiusY = (try? c.decodeIfPresent(Double.self, forKey: .radiusY)) ?? 0.15
        angle = (try? c.decodeIfPresent(Double.self, forKey: .angle)) ?? 0
        feather = (try? c.decodeIfPresent(Double.self, forKey: .feather)) ?? 50
        strokes = (try? c.decodeIfPresent([BrushStroke].self, forKey: .strokes)) ?? []
        lumLow = (try? c.decodeIfPresent(Double.self, forKey: .lumLow)) ?? 0.5
        lumHigh = (try? c.decodeIfPresent(Double.self, forKey: .lumHigh)) ?? 1
        lumSmoothness = (try? c.decodeIfPresent(Double.self, forKey: .lumSmoothness)) ?? 0.15
        pickL = (try? c.decodeIfPresent(Double.self, forKey: .pickL)) ?? 0.6
        pickA = (try? c.decodeIfPresent(Double.self, forKey: .pickA)) ?? 0
        pickB = (try? c.decodeIfPresent(Double.self, forKey: .pickB)) ?? 0
        colorAmount = (try? c.decodeIfPresent(Double.self, forKey: .colorAmount)) ?? 50
        hasPickedColor = (try? c.decodeIfPresent(Bool.self, forKey: .hasPickedColor)) ?? false
    }

    var title: String {
        if kind == .subject && invert { return "Background" }
        return kind.rawValue
    }
}

/// Lightroom's local adjustment sliders (−100…100 unless noted).
struct LocalAdjustments: Codable, Hashable {
    var temperature = 0.0
    var tint = 0.0
    var exposure = 0.0        // EV, −4…4
    var contrast = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var whites = 0.0
    var blacks = 0.0
    var texture = 0.0
    var clarity = 0.0
    var dehaze = 0.0
    var saturation = 0.0
    var sharpness = 0.0
    var colorHue = 0.0        // 0…360
    var colorSaturation = 0.0 // 0…100

    var isNeutral: Bool { self == LocalAdjustments() }
    var presenceActive: Bool { texture != 0 || clarity != 0 || dehaze != 0 }

    var presence: EffectsSettings {
        var e = EffectsSettings()
        e.texture = texture
        e.clarity = clarity
        e.dehaze = dehaze
        return e
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case temperature, tint, exposure, contrast, highlights, shadows, whites, blacks
        case texture, clarity, dehaze, saturation, sharpness, colorHue, colorSaturation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v(_ key: CodingKeys) -> Double { (try? c.decodeIfPresent(Double.self, forKey: key)) ?? 0 }
        temperature = v(.temperature)
        tint = v(.tint)
        exposure = v(.exposure)
        contrast = v(.contrast)
        highlights = v(.highlights)
        shadows = v(.shadows)
        whites = v(.whites)
        blacks = v(.blacks)
        texture = v(.texture)
        clarity = v(.clarity)
        dehaze = v(.dehaze)
        saturation = v(.saturation)
        sharpness = v(.sharpness)
        colorHue = v(.colorHue)
        colorSaturation = v(.colorSaturation)
    }
}

/// One mask: components combined top to bottom, plus its adjustments.
struct MaskLayer: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var visible = true
    var components: [MaskComponent] = []
    var adjustments = LocalAdjustments()

    init(name: String, components: [MaskComponent]) {
        self.name = name
        self.components = components
    }

    private enum CodingKeys: String, CodingKey { case id, name, visible, components, adjustments }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Mask"
        visible = (try? c.decodeIfPresent(Bool.self, forKey: .visible)) ?? true
        components = (try? c.decodeIfPresent([MaskComponent].self, forKey: .components)) ?? []
        adjustments = (try? c.decodeIfPresent(LocalAdjustments.self, forKey: .adjustments)) ?? LocalAdjustments()
    }
}
