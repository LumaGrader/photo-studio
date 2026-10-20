import Foundation
import ImageIO
import CoreGraphics

/// Decodes thumbnails and previews with ImageIO (JPEG, HEIC, and the RAW formats
/// macOS supports), off the main thread.
///
/// Speed rules:
/// - RAW files: use the camera's embedded JPEG preview first; decode the sensor
///   data only when the preview is missing or too small.
/// - Grid thumbnails are kept on disk, so reopening a folder is instant.
/// - Only a few decodes run at once, newest request first, and requests from
///   cells that scrolled away are dropped.
final class ImageLoader {
    static let shared = ImageLoader()

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let memoryCache = NSCache<NSString, Box>()
    private let diskCache = ThumbnailDiskCache()
    private let limiter = DecodeLimiter(
        limit: max(2, min(6, ProcessInfo.processInfo.activeProcessorCount / 2)))

    private init() {
        memoryCache.totalCostLimit = 768 * 1024 * 1024 // bytes of decoded pixels
    }

    /// Long side of an image file in pixels, read from its header (no decode).
    static func pixelLongSide(of url: URL) -> CGFloat? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        else { return nil }
        return CGFloat(max(width, height))
    }

    func cachedImage(for url: URL, maxPixel: Int) -> CGImage? {
        memoryCache.object(forKey: Self.key(url, maxPixel))?.image
    }

    /// Returns nil when the file can't be read or the calling task was cancelled.
    func image(for url: URL, maxPixel: Int) async -> CGImage? {
        let key = Self.key(url, maxPixel)
        if let hit = memoryCache.object(forKey: key) { return hit.image }

        let useDisk = maxPixel == ThumbnailDiskCache.maxPixel
        let disk = diskCache

        // 1. Disk cache (cheap, not limited).
        if useDisk {
            let cached = await Task.detached(priority: .userInitiated) {
                disk.load(for: url)
            }.value
            if let cached {
                remember(cached, key: key)
                return cached
            }
        }

        // 2. Decode, a few at a time.
        await limiter.acquire()
        if Task.isCancelled {
            await limiter.release()
            return nil
        }
        let decoded = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let image = ImageLoader.decode(url: url, maxPixel: maxPixel)
            if useDisk, let image { disk.store(image, for: url) }
            return image
        }.value
        await limiter.release()

        if let decoded { remember(decoded, key: key) }
        return decoded
    }

    // MARK: - With edits

    /// The photo as it should be shown: with its Develop edits, if any.
    func displayImage(for photo: Photo, maxPixel: Int) async -> CGImage? {
        if photo.hasEdits {
            return await editedImage(for: photo, maxPixel: maxPixel)
        }
        return await image(for: photo.url, maxPixel: maxPixel)
    }

    func cachedDisplayImage(for photo: Photo, maxPixel: Int) -> CGImage? {
        if photo.hasEdits {
            return memoryCache.object(forKey: Self.editedKey(photo, maxPixel))?.image
        }
        return cachedImage(for: photo.url, maxPixel: maxPixel)
    }

    private func editedImage(for photo: Photo, maxPixel: Int) async -> CGImage? {
        let key = Self.editedKey(photo, maxPixel)
        if let hit = memoryCache.object(forKey: key) { return hit.image }

        await limiter.acquire()
        if Task.isCancelled {
            await limiter.release()
            return nil
        }
        let url = photo.url
        let settings = photo.develop
        let rendered = await Task.detached(priority: .userInitiated) {
            DevelopRenderer.render(url: url, settings: settings, maxPixel: maxPixel)
        }.value
        await limiter.release()

        if let rendered { remember(rendered, key: key) }
        return rendered
    }

    private static func editedKey(_ photo: Photo, _ maxPixel: Int) -> NSString {
        "edit|\(maxPixel)|\(photo.develop.cacheKey)|\(photo.url.path)" as NSString
    }

    // MARK: - Cache

    private func remember(_ image: CGImage, key: NSString) {
        memoryCache.setObject(Box(image), forKey: key, cost: image.bytesPerRow * image.height)
    }

    private static func key(_ url: URL, _ maxPixel: Int) -> NSString {
        "\(maxPixel)|\(url.path)" as NSString
    }

    private static func decode(url: URL, maxPixel: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }

        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true, // apply EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]

        // How big the preview must be: for thumbnails/previews a decent size is enough;
        // for 100% zoom (maxPixel ≥ the photo itself) it must be (nearly) full size.
        var required = min(maxPixel * 3 / 4, 1536)
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            let longSide = max(width, height)
            if longSide > 0, maxPixel >= longSide { required = longSide * 9 / 10 }
        }

        // Fast path: embedded preview (RAW camera JPEG / EXIF thumbnail).
        options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        if let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
           max(preview.width, preview.height) >= required {
            return preview
        }

        // Slow path: decode the full image, then scale down.
        options.removeValue(forKey: kCGImageSourceCreateThumbnailFromImageIfAbsent)
        options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Lets at most `limit` decodes run at once. The newest waiting request goes
/// first, so what's on screen now beats what was scrolled past.
actor DecodeLimiter {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeLast().resume() // slot passes straight to the newest waiter
        }
    }
}
