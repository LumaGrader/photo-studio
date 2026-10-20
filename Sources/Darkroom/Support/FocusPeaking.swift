import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics

/// Focus Check: marks in-focus edges on a photo (focus peaking) and finds its sharpest area.
///
/// Sharpness = fine detail that a slight blur removes: the difference between two Gaussian
/// blurs (0.7 px and 2 px) of the gamma-encoded luminance, so noise is damped and
/// out-of-focus areas stay quiet. Strong differences are painted red over the photo.
enum FocusPeaking {
    enum Sensitivity: Int, CaseIterable, Identifiable {
        case low = 0, medium = 1, high = 2
        var id: Int { rawValue }
        var title: String { ["Low", "Medium", "High"][rawValue] }
        /// Gain applied to the detail before the 0.5 threshold: an edge counts as in focus
        /// above 0.05 / 0.03 / 0.018 of fine detail (gamma-encoded), tuned so a slightly soft
        /// (1.5 px) mid-contrast edge only shows on High.
        fileprivate var gain: Float { [10, 17, 28][rawValue] }
    }

    struct Result {
        /// The photo with the in-focus edges painted.
        let image: CGImage
        /// Centre of the sharpest area, 0…1 from the top-left (nil for a flat image).
        let sharpest: CGPoint?
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Thread-safe; call off the main thread (a full-size photo takes a moment).
    static func analyze(_ cgImage: CGImage, sensitivity: Sensitivity) -> Result? {
        let input = CIImage(cgImage: cgImage)
        let extent = input.extent
        guard extent.width > 8, extent.height > 8 else { return nil }

        let detail = self.detail(of: input).cropped(to: extent)
        let gain = sensitivity.gain
        let amplified = detail.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(gain), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: CGFloat(gain), y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: CGFloat(gain), y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])

        // Binary mask, widened a pixel so thin edges stay visible when the photo is scaled down.
        let threshold = CIFilter.colorThreshold()
        threshold.inputImage = amplified
        threshold.threshold = 0.5
        var mask = threshold.outputImage ?? amplified
        let longSide = max(extent.width, extent.height)
        if longSide > 3000 {
            let widen = CIFilter.morphologyMaximum()
            widen.inputImage = mask
            widen.radius = Float(min(3, longSide / 3000))
            mask = (widen.outputImage ?? mask).cropped(to: extent)
        }

        // Red where in focus (premultiplied: colour ≤ alpha).
        let paint = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0.12, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0.12, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0),
        ])
        let output = paint.composited(over: input).cropped(to: extent)
        guard let painted = context.createCGImage(output, from: extent, format: .RGBA8,
                                                  colorSpace: cgImage.colorSpace ?? sRGB)
        else { return nil }

        return Result(image: painted, sharpest: sharpestPoint(amplified, extent: extent))
    }

    /// Fine-detail strength (grey, 0… ) of the photo.
    private static func detail(of image: CIImage) -> CIImage {
        let gray = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0, kCIInputBrightnessKey: 0, kCIInputContrastKey: 1,
        ])
        // Gamma-encoded, so dark and bright areas count alike (like the eye).
        let clamped = gray.applyingFilter("CILinearToSRGBToneCurve").clampedToExtent()
        let fine = clamped.applyingGaussianBlur(sigma: 0.7)
        let coarse = clamped.applyingGaussianBlur(sigma: 2.0)
        return fine.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: coarse])
    }

    /// The densest area of detail: the detail map averaged down to a small grid, smoothed over
    /// 3×3 cells, then the strongest cell.
    private static func sharpestPoint(_ detail: CIImage, extent: CGRect) -> CGPoint? {
        let columns = 48
        let scale = CGFloat(columns) / extent.width
        let lanczos = CIFilter.lanczosScaleTransform()
        lanczos.inputImage = detail.clampedToExtent().cropped(to: extent)
        lanczos.scale = Float(scale)
        lanczos.aspectRatio = 1
        guard let small = lanczos.outputImage else { return nil }
        let smallExtent = small.extent.integral
        guard smallExtent.width >= 3, smallExtent.height >= 3,
              let grid = context.createCGImage(small, from: smallExtent, format: .RGBA8, colorSpace: sRGB)
        else { return nil }

        let w = grid.width, h = grid.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(grid, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        // Row 0 of the buffer is the top of the image.
        func value(_ x: Int, _ y: Int) -> Int { Int(pixels[(y * w + x) * 4]) }
        var best = (score: 0, x: 0, y: 0)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                var sum = 0
                for dy in -1...1 { for dx in -1...1 { sum += value(x + dx, y + dy) } }
                if sum > best.score { best = (sum, x, y) }
            }
        }
        guard best.score > 9 * 4 else { return nil } // nothing sharp anywhere
        return CGPoint(x: (CGFloat(best.x) + 0.5) / CGFloat(w), y: (CGFloat(best.y) + 0.5) / CGFloat(h))
    }
}
