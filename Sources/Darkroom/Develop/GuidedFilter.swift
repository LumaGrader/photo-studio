import Foundation
import CoreImage

/// Edge-aware "local brightness" for Lightroom-style Highlights / Shadows
/// (ported from lumagrader src/engine/localBase.js).
///
/// A self-guided filter (He et al.) on log2 luminance, computed on a small ≤256 px copy.
/// It smooths inside regions but keeps strong edges (no halos). The result is two
/// coefficients per low-res pixel (A, B); at full resolution the GPU computes
///     base = A · log2(Y) + B
/// from bilinearly upsampled A, B ("fast guided filter"), so it stays edge-aware at any
/// size and the preview, 100% zoom and export all match.
enum GuidedFilter {
    static let maxSide = 256
    static let radiusFraction = 0.057  // box radius as a fraction of the long side
    static let epsilon: Float = 0.163  // edge threshold in EV² (fitted with the tone zones)
    static let logFloor: Float = -14

    /// Coefficient image (A in red, B in green) covering `extent`, or nil on failure.
    /// `image` should be the photo before any edits (as-shot white balance, no exposure).
    static func coefficientImage(for image: CIImage, context: CIContext) -> CIImage? {
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 2, extent.height >= 2 else { return nil }

        // 1. Small linear-light copy.
        let scale = min(1, CGFloat(maxSide) / max(extent.width, extent.height))
        let w = max(2, Int((extent.width * scale).rounded()))
        let h = max(2, Int((extent.height * scale).rounded()))
        let small = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / extent.width, y: CGFloat(h) / extent.height))
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))

        var pixels = [Float](repeating: 0, count: w * h * 4)
        guard let linear = CGColorSpace(name: CGColorSpace.linearSRGB) else { return nil }
        pixels.withUnsafeMutableBytes { buffer in
            context.render(small, toBitmap: buffer.baseAddress!, rowBytes: w * 16,
                           bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           format: .RGBAf, colorSpace: linear)
        }

        // 2. log2 luminance.
        var logY = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = pixels[i * 4], g = pixels[i * 4 + 1], b = pixels[i * 4 + 2]
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            logY[i] = max(logFloor, log2(max(y, 1e-6)))
        }

        // 3. Guided filter coefficients.
        let radius = max(1, Int((Double(max(w, h)) * radiusFraction).rounded()))
        let squares = logY.map { $0 * $0 }
        let mean = boxBlur(logY, w, h, radius)
        let meanSq = boxBlur(squares, w, h, radius)
        var a = [Float](repeating: 0, count: w * h)
        var b = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let variance = max(0, meanSq[i] - mean[i] * mean[i])
            a[i] = variance / (variance + epsilon)
            b[i] = mean[i] - a[i] * mean[i]
        }
        let smoothA = boxBlur(a, w, h, radius)
        let smoothB = boxBlur(b, w, h, radius)

        // 4. Float image, stretched over the photo's extent (bilinear sampling).
        var coefficients = [Float](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            coefficients[i * 4] = smoothA[i]
            coefficients[i * 4 + 1] = smoothB[i]
            coefficients[i * 4 + 3] = 1
        }
        let data = coefficients.withUnsafeBufferPointer { Data(buffer: $0) }
        let map = CIImage(bitmapData: data, bytesPerRow: w * 16,
                          size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
        return map
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(w), y: extent.height / CGFloat(h)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    /// Separable running-sum box filter with edge clamping.
    private static func boxBlur(_ source: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
        var temp = [Float](repeating: 0, count: w * h)
        var output = [Float](repeating: 0, count: w * h)
        let n = Float(2 * r + 1)
        for y in 0..<h {
            let row = y * w
            var accumulator: Float = 0
            for x in -r...r { accumulator += source[row + min(w - 1, max(0, x))] }
            for x in 0..<w {
                temp[row + x] = accumulator / n
                accumulator += source[row + min(w - 1, x + r + 1)] - source[row + max(0, x - r)]
            }
        }
        for x in 0..<w {
            var accumulator: Float = 0
            for y in -r...r { accumulator += temp[min(h - 1, max(0, y)) * w + x] }
            for y in 0..<h {
                output[y * w + x] = accumulator / n
                accumulator += temp[min(h - 1, y + r + 1) * w + x] - temp[max(0, y - r) * w + x]
            }
        }
        return output
    }
}
