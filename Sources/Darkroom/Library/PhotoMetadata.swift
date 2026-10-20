import Foundation
import ImageIO

/// Camera info read from the file (EXIF/TIFF), formatted for display.
struct PhotoMetadata {
    var camera: String?
    var lens: String?
    var focalLength: String?
    var aperture: String?
    var shutter: String?
    var iso: String?
    var captured: String?
    var dimensions: String?

    /// "ISO 800   35 mm   f/2.8   1/250 s" (like the line under Lightroom's histogram).
    var exposureLine: String {
        [iso, focalLength, aperture, shutter].compactMap { $0 }.joined(separator: "   ")
    }

    struct Row: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    var rows: [Row] {
        let all: [(String, String?)] = [
            ("Captured", captured), ("Camera", camera), ("Lens", lens), ("Focal length", focalLength),
            ("Aperture", aperture), ("Shutter", shutter), ("ISO", iso), ("Dimensions", dimensions),
        ]
        return all.compactMap { pair in pair.1.map { Row(label: pair.0, value: $0) } }
    }

    static func load(url: URL) -> PhotoMetadata {
        var m = PhotoMetadata()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return m }
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let aux = p[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]

        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        if let model {
            // Most models already start with the brand ("Canon EOS R6").
            if let make, !model.lowercased().hasPrefix(make.lowercased().components(separatedBy: " ").first ?? "") {
                m.camera = "\(make) \(model)"
            } else {
                m.camera = model
            }
        }
        m.lens = (exif[kCGImagePropertyExifLensModel] as? String) ?? (aux[kCGImagePropertyExifAuxLensModel] as? String)
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
            m.focalLength = "\(Int(focal.rounded())) mm"
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double {
            m.aperture = String(format: f < 10 ? "f/%.1f" : "f/%.0f", f)
        }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            m.shutter = t >= 0.4 ? String(format: "%.1f s", t) : "1/\(Int((1 / t).rounded())) s"
        }
        if let isoValues = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let iso = isoValues.first {
            m.iso = "ISO \(iso)"
        }
        if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            m.captured = Self.prettyDate(date)
        }
        if let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
            m.dimensions = "\(w) × \(h)"
        }
        return m
    }

    /// "2026:10:12 19:34:48" → "Oct 12, 2026  7:34 PM"
    private static func prettyDate(_ exif: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: exif) else { return exif }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: date)
    }
}

/// Small in-memory cache so panels don't re-read EXIF on every redraw.
final class MetadataCache {
    static let shared = MetadataCache()

    private final class Box {
        let value: PhotoMetadata
        init(_ value: PhotoMetadata) { self.value = value }
    }

    private let cache = NSCache<NSURL, Box>()

    func metadata(for url: URL) async -> PhotoMetadata {
        if let hit = cache.object(forKey: url as NSURL) { return hit.value }
        let value = await Task.detached(priority: .utility) { PhotoMetadata.load(url: url) }.value
        cache.setObject(Box(value), forKey: url as NSURL)
        return value
    }
}
