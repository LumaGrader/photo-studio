import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Auto-Rotate Portraits: finds vertical shots the camera saved sideways (its auto-rotate
/// off, so the file says "normal" orientation) by looking for upright people.
///
/// The preview is checked as it is, turned right and turned left; the way with the most
/// upright faces (and people) wins. Photos without people are left alone — there's nothing
/// reliable to tell up from sideways in a landscape or a bird.
enum AutoOrient {
    /// Quarter turn to apply: +90 = clockwise (Rotate Right), -90 = counter-clockwise.
    enum Turn: Int {
        case upright = 0
        case clockwise = 90
        case counterClockwise = -90
    }

    private static let checkSize = 768

    /// True when the file has no orientation of its own (missing or 1 = "normal"), so a
    /// vertical shot would show sideways. Files the camera already rotated are skipped.
    static func needsCheck(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return false }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation == 1
    }

    /// The turn that makes the photo upright, judged from people in it. Thread-safe; call
    /// off the main thread (about 0.1 s per photo).
    static func detect(_ url: URL) -> Turn {
        guard needsCheck(url), let image = preview(url) else { return .upright }
        let up = score(image, .up)
        let right = score(image, .right)  // pixels need a clockwise turn to be upright
        let left = score(image, .left)    // … a counter-clockwise turn
        let best = max(right, left)
        // Turn only when sideways people clearly win over the photo as it is.
        guard best >= 0.6, best > up * 2 + 0.2 else { return .upright }
        return right >= left ? .clockwise : .counterClockwise
    }

    /// Small preview: the embedded JPEG of a RAW, or a scaled-down image (EXIF orientation
    /// is 1 here, so nothing is turned).
    private static func preview(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: checkSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// How strongly the photo shows upright people when read with `orientation`.
    private static func score(_ image: CGImage, _ orientation: CGImagePropertyOrientation) -> Double {
        let faces = VNDetectFaceRectanglesRequest()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        do {
            try handler.perform([faces, humans])
        } catch {
            return 0
        }
        var total = 0.0
        for face in faces.results ?? [] {
            // A face tilted more than 45° in this reading isn't upright.
            if let roll = face.roll?.doubleValue, abs(roll) > .pi / 4 { continue }
            let size = min(1, Double(face.boundingBox.height) * 8) // tiny faces count less
            total += Double(face.confidence) * (0.5 + 0.5 * size)
        }
        for human in humans.results ?? [] {
            total += 0.5 * Double(human.confidence)
        }
        return total
    }
}
