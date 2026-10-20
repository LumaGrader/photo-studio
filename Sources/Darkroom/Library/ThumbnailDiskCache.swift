import Foundation
import ImageIO
import CoreGraphics
import CryptoKit

/// Grid thumbnails saved as small JPEGs in ~/Library/Caches/Darkroom/Thumbnails.
/// The key includes the file's size and modification date, so an edited or
/// replaced file gets a fresh thumbnail. Safe to delete at any time.
final class ThumbnailDiskCache {
    static let maxPixel = 512

    private let directory: URL?

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let dir = caches?.appendingPathComponent("Darkroom/Thumbnails", isDirectory: true)
        if let dir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        directory = dir
    }

    func load(for url: URL) -> CGImage? {
        guard let file = cacheFile(for: url),
              let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    func store(_ image: CGImage, for url: URL) {
        guard let file = cacheFile(for: url) else { return }
        let temp = file.appendingPathExtension("tmp")
        guard let destination = CGImageDestinationCreateWithURL(
            temp as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        if CGImageDestinationFinalize(destination) {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.moveItem(at: temp, to: file)
        } else {
            try? FileManager.default.removeItem(at: temp)
        }
    }

    private func cacheFile(for url: URL) -> URL? {
        guard let directory,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return nil }
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(values.fileSize ?? 0)|\(modified)|\(Self.maxPixel)"
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".jpg")
    }
}
