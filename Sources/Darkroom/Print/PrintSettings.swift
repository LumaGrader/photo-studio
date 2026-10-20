import Foundation
import CoreGraphics

/// Print module settings (Single Image layout), remembered between launches.
/// Lengths are in inches, like Lightroom's Print module.
struct PrintSettings: Codable, Equatable {
    enum Fit: String, Codable, CaseIterable, Identifiable {
        case fit = "Fit"
        case fill = "Fill"
        var id: String { rawValue }
    }

    enum Sharpening: String, Codable, CaseIterable, Identifiable {
        case off = "Off", low = "Low", standard = "Standard", high = "High"
        var id: String { rawValue }

        /// Unsharp-mask intensity.
        var intensity: Double {
            switch self {
            case .off: return 0
            case .low: return 0.35
            case .standard: return 0.6
            case .high: return 0.9
            }
        }
    }

    enum Media: String, Codable, CaseIterable, Identifiable {
        case matte = "Matte", glossy = "Glossy"
        var id: String { rawValue }
    }

    enum Intent: String, Codable, CaseIterable, Identifiable {
        case perceptual = "Perceptual"
        case relative = "Relative"
        var id: String { rawValue }

        var cgIntent: CGColorRenderingIntent {
            self == .perceptual ? .perceptual : .relativeColorimetric
        }
    }

    enum BorderColor: String, Codable, CaseIterable, Identifiable {
        case black = "Black", white = "White"
        var id: String { rawValue }
    }

    // Layout
    var marginTop = 0.5
    var marginBottom = 0.5
    var marginLeft = 0.5
    var marginRight = 0.5
    var fit: Fit = .fit
    /// Turns the photo 90° when that makes it bigger on the page.
    var rotateToFit = true
    /// Inner stroke on the photo, in points (0 = none).
    var borderWidth = 0.0
    var borderColor: BorderColor = .black

    // Print job
    var resolution = 300
    var sharpening: Sharpening = .standard
    var media: Media = .glossy
    /// Print Adjustment: compensates for prints that come out darker / flatter than the screen.
    var printAdjustment = false
    var brightness = 0.0   // -50…50
    var contrast = 0.0     // -50…50

    // Colour management (the app manages colour)
    /// Path of the ICC paper profile; nil = sRGB, printer manages colour.
    var profilePath: String?
    var intent: Intent = .perceptual
    /// Soft proof in the preview: paper white and ink black (absolute colorimetric).
    var simulatePaper = false

    static let resolutions = [240, 300, 360, 600, 720]

    // MARK: - Persistence

    private static let key = "print.settings"

    static func load() -> PrintSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(PrintSettings.self, from: data)
        else { return PrintSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

/// Where the photo goes on one page, in points from the page's top-left corner.
struct PrintPageLayout: Equatable {
    var paper: CGSize
    /// Area inside the margins.
    var cell: CGRect
    /// The photo itself.
    var image: CGRect
    /// The photo is turned 90° (Rotate to Fit).
    var rotated: Bool

    /// - Parameters:
    ///   - imageable: the printer's printable area (from the top-left); margins never go outside it.
    ///   - photoSize: developed photo size in pixels (only the aspect ratio matters).
    static func make(paper: CGSize, imageable: CGRect, photoSize: CGSize, settings s: PrintSettings) -> PrintPageLayout {
        let inch: CGFloat = 72
        var cell = CGRect(x: CGFloat(s.marginLeft) * inch,
                          y: CGFloat(s.marginTop) * inch,
                          width: paper.width - CGFloat(s.marginLeft + s.marginRight) * inch,
                          height: paper.height - CGFloat(s.marginTop + s.marginBottom) * inch)
        // Keep inside what the printer can reach.
        if !imageable.isEmpty { cell = cell.intersection(imageable) }
        if cell.isNull || cell.width < 1 || cell.height < 1 {
            cell = imageable.isEmpty ? CGRect(origin: .zero, size: paper) : imageable
        }

        guard photoSize.width > 0, photoSize.height > 0 else {
            return PrintPageLayout(paper: paper, cell: cell, image: cell, rotated: false)
        }
        let photoLandscape = photoSize.width > photoSize.height
        let cellLandscape = cell.width > cell.height
        let rotated = s.rotateToFit && photoSize.width != photoSize.height && photoLandscape != cellLandscape
        let aspect = rotated ? photoSize.height / photoSize.width : photoSize.width / photoSize.height

        let image: CGRect
        if s.fit == .fill {
            image = cell
        } else {
            var w = cell.width
            var h = w / aspect
            if h > cell.height {
                h = cell.height
                w = h * aspect
            }
            image = CGRect(x: cell.midX - w / 2, y: cell.midY - h / 2, width: w, height: h)
        }
        return PrintPageLayout(paper: paper, cell: cell, image: image, rotated: rotated)
    }

    /// Pixels needed for the photo at `ppi`.
    func pixelSize(ppi: Int) -> CGSize {
        CGSize(width: (image.width / 72 * CGFloat(ppi)).rounded(),
               height: (image.height / 72 * CGFloat(ppi)).rounded())
    }
}
