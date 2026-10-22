import Foundation
import AppKit
import CoreImage
import ImageIO

/// Text or logo stamped on exported photos.
struct WatermarkSettings: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case text = "Text"
        case image = "Logo (PNG)"
        var id: String { rawValue }
    }

    enum Position: String, Codable, CaseIterable, Identifiable {
        case topLeft = "Top left", top = "Top", topRight = "Top right"
        case left = "Left", center = "Centre", right = "Right"
        case bottomLeft = "Bottom left", bottom = "Bottom", bottomRight = "Bottom right"
        var id: String { rawValue }

        /// 0…1 across and down (0 = left / top).
        var anchor: (x: CGFloat, y: CGFloat) {
            switch self {
            case .topLeft: return (0, 0)
            case .top: return (0.5, 0)
            case .topRight: return (1, 0)
            case .left: return (0, 0.5)
            case .center: return (0.5, 0.5)
            case .right: return (1, 0.5)
            case .bottomLeft: return (0, 1)
            case .bottom: return (0.5, 1)
            case .bottomRight: return (1, 1)
            }
        }
    }

    var enabled = false
    var kind = Kind.text
    var text = "© Your Name"
    var imagePath = ""
    /// Width of the watermark, % of the photo's long edge.
    var size = 15.0
    /// 0…100.
    var opacity = 70.0
    var position = Position.bottomRight
    /// Gap to the edges, % of the long edge.
    var margin = 3.0

    var isUsable: Bool {
        enabled && (kind == .text ? !text.trimmingCharacters(in: .whitespaces).isEmpty : !imagePath.isEmpty)
    }
}

enum WatermarkRenderer {
    /// The photo with the watermark over it (Core Image coordinates, y up).
    static func apply(_ w: WatermarkSettings, to photo: CIImage) -> CIImage {
        guard w.isUsable else { return photo }
        let extent = photo.extent
        let longEdge = max(extent.width, extent.height)
        let targetWidth = max(8, longEdge * CGFloat(min(max(w.size, 1), 80)) / 100)
        guard let mark = markImage(w, width: targetWidth) else { return photo }
        var image = CIImage(cgImage: mark)
        let scale = targetWidth / image.extent.width
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let size = image.extent.size
        let margin = longEdge * CGFloat(min(max(w.margin, 0), 20)) / 100
        let anchor = w.position.anchor
        let x = extent.minX + margin + (extent.width - 2 * margin - size.width) * anchor.x
        // Anchor y counts from the top; Core Image's y goes up.
        let y = extent.minY + margin + (extent.height - 2 * margin - size.height) * (1 - anchor.y)
        image = image.transformed(by: CGAffineTransform(translationX: x - image.extent.minX, y: y - image.extent.minY))
        let alpha = CGFloat(min(max(w.opacity, 0), 100) / 100)
        image = image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
        ])
        return image.composited(over: photo).cropped(to: extent)
    }

    /// Logo file, or the text drawn white with a soft shadow.
    private static func markImage(_ w: WatermarkSettings, width: CGFloat) -> CGImage? {
        switch w.kind {
        case .image:
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: w.imagePath) as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        case .text:
            return textImage(w.text, width: width)
        }
    }

    private static func textImage(_ text: String, width: CGFloat) -> CGImage? {
        let font = NSFont(name: "AvenirNext-DemiBold", size: 100) ?? NSFont.systemFont(ofSize: 100, weight: .semibold)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white, .shadow: shadow,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let measured = string.size()
        guard measured.width > 0 else { return nil }
        // Draw at the final size so small text stays crisp.
        let scale = width / measured.width
        let pad: CGFloat = 12
        let w = Int((measured.width * scale + pad * 2).rounded(.up))
        let h = Int((measured.height * scale + pad * 2).rounded(.up))
        guard w > 0, h > 0,
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        context.scaleBy(x: scale, y: scale)
        string.draw(at: NSPoint(x: pad / scale, y: pad / scale))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

/// Saved Export dialog settings.
struct ExportPreset: Codable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var format: String
    var quality: Double
    var resize: Bool
    var longEdge: Int
    var folderPath: String
    var naming: String
    var customName: String
    var stripLocation: Bool
    var watermark: WatermarkSettings

    static let storageKey = "export.presets"

    /// Options for exporting with this preset. A preset without its own folder exports to
    /// `defaultFolder` (nil = can't export).
    func options(defaultFolder: URL?) -> ExportOptions? {
        let folder = folderPath.isEmpty ? defaultFolder : URL(fileURLWithPath: folderPath, isDirectory: true)
        guard let folder else { return nil }
        return ExportOptions(
            format: ExportFormat(rawValue: format) ?? .jpeg,
            quality: quality,
            longEdge: resize ? max(64, min(longEdge, 20000)) : nil,
            folder: folder,
            naming: ExportNaming(rawValue: naming) ?? .original,
            customName: customName,
            stripLocation: stripLocation,
            watermark: watermark)
    }

    static func load() -> [ExportPreset] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let presets = try? JSONDecoder().decode([ExportPreset].self, from: data) else { return [] }
        return presets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func save(_ presets: [ExportPreset]) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
