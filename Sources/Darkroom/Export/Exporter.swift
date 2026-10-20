import Foundation
import CoreImage
import ImageIO

enum ExportFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG"
    case tiff = "TIFF (16-bit)"
    case png = "PNG"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .tiff: return "tif"
        case .png: return "png"
        }
    }

    var typeIdentifier: CFString {
        switch self {
        case .jpeg: return "public.jpeg" as CFString
        case .tiff: return "public.tiff" as CFString
        case .png: return "public.png" as CFString
        }
    }
}

enum ExportNaming: String, CaseIterable, Identifiable {
    case original = "Original name"
    case custom = "Custom name + number"

    var id: String { rawValue }
}

struct ExportOptions {
    var format: ExportFormat
    var quality: Double          // JPEG 0…1
    var longEdge: Int?           // nil = full size
    var folder: URL
    var naming: ExportNaming
    var customName: String
    var stripLocation: Bool
    var watermark = WatermarkSettings()
}

enum ExportError: LocalizedError {
    case unreadable(String)
    case renderFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "\(name): can't read the file."
        case .renderFailed(let name): return "\(name): couldn't render the edits."
        case .writeFailed(let name): return "\(name): couldn't save the file."
        }
    }
}

/// Renders one photo with its edits at export size and writes it with its metadata.
/// Never overwrites: an existing name gets " (2)", " (3)", …
enum Exporter {
    static func export(_ photo: Photo, number: Int, options: ExportOptions) throws -> URL {
        guard let source = DevelopRenderer.makeSource(url: photo.url, maxPixel: options.longEdge) else {
            throw ExportError.unreadable(photo.fileName)
        }
        guard var output = DevelopRenderer.apply(photo.develop, to: source, cube: ToneCubeCache()) else {
            throw ExportError.renderFailed(photo.fileName)
        }
        output = WatermarkRenderer.apply(options.watermark, to: output)
        let extent = output.extent.integral
        let pixelFormat: CIFormat = options.format == .tiff ? .RGBA16 : .RGBA8
        guard !extent.isEmpty, !extent.isInfinite,
              let image = DevelopRenderer.context.createCGImage(
                output, from: extent, format: pixelFormat, colorSpace: DevelopRenderer.sRGB)
        else {
            throw ExportError.renderFailed(photo.fileName)
        }

        let url = uniqueURL(in: options.folder, baseName: baseName(for: photo, number: number, options: options),
                            fileExtension: options.format.fileExtension)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, options.format.typeIdentifier, 1, nil) else {
            throw ExportError.writeFailed(photo.fileName)
        }
        var properties = metadata(for: photo.url, width: image.width, height: image.height,
                                  stripLocation: options.stripLocation)
        addOwnMetadata(photo.meta, to: &properties)
        if options.format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(options.quality, 0.1), 1)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.writeFailed(photo.fileName)
        }
        return url
    }

    /// Title, caption, creator, copyright and keywords (IPTC; macOS also writes them as XMP).
    private static func addOwnMetadata(_ meta: PhotoMeta, to properties: inout [CFString: Any]) {
        guard !meta.isEmpty else { return }
        var iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        if !meta.title.isEmpty { iptc[kCGImagePropertyIPTCObjectName] = meta.title }
        if !meta.caption.isEmpty {
            iptc[kCGImagePropertyIPTCCaptionAbstract] = meta.caption
            tiff[kCGImagePropertyTIFFImageDescription] = meta.caption
        }
        if !meta.creator.isEmpty {
            iptc[kCGImagePropertyIPTCByline] = [meta.creator]
            tiff[kCGImagePropertyTIFFArtist] = meta.creator
        }
        if !meta.copyright.isEmpty {
            iptc[kCGImagePropertyIPTCCopyrightNotice] = meta.copyright
            tiff[kCGImagePropertyTIFFCopyright] = meta.copyright
        }
        if !meta.keywords.isEmpty { iptc[kCGImagePropertyIPTCKeywords] = meta.keywords }
        properties[kCGImagePropertyIPTCDictionary] = iptc
        properties[kCGImagePropertyTIFFDictionary] = tiff
    }

    static func baseName(for photo: Photo, number: Int, options: ExportOptions) -> String {
        switch options.naming {
        case .original:
            return photo.url.deletingPathExtension().lastPathComponent
        case .custom:
            let cleaned = sanitized(options.customName)
            return "\(cleaned.isEmpty ? "Photo" : cleaned)-\(String(format: "%03d", number))"
        }
    }

    static func sanitized(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return name.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uniqueURL(in folder: URL, baseName: String, fileExtension: String) -> URL {
        var url = folder.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(baseName) (\(counter))").appendingPathExtension(fileExtension)
            counter += 1
        }
        return url
    }

    /// Camera metadata from the original, fixed up for the new pixels: orientation is
    /// already applied, sizes changed, colour info comes from the new image.
    private static func metadata(for url: URL, width: Int, height: Int, stripLocation: Bool) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return [:] }

        properties[kCGImagePropertyOrientation] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                    kCGImagePropertyColorModel, kCGImagePropertyProfileName, kCGImagePropertyHasAlpha,
                    kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            properties.removeValue(forKey: key)
        }
        if stripLocation {
            properties.removeValue(forKey: kCGImagePropertyGPSDictionary)
        }
        return properties
    }
}
