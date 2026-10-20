import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Global tone: Blacks/Whites (end points), Shadows/Highlights (soft bumps),
/// Contrast (S-curve around the middle). Works on luminance in sRGB-encoded
/// values and keeps colour by scaling RGB together.
struct ToneCurve {
    let contrast: Double   // -1...1
    let highlights: Double
    let shadows: Double
    let whites: Double
    let blacks: Double

    init(_ settings: DevelopSettings) {
        contrast = settings.contrast / 100
        highlights = settings.highlights / 100
        shadows = settings.shadows / 100
        whites = settings.whites / 100
        blacks = settings.blacks / 100
    }

    /// Monotonic for every slider combination (checked by hand: slope stays > 0).
    func map(_ x: Double) -> Double {
        let low = -0.15 * blacks       // +Blacks lifts, -Blacks crushes
        let high = 1 - 0.15 * whites   // +Whites brightens, -Whites dims
        var y = clamp((x - low) / (high - low))

        let shadowBump = 6.75 * y * (1 - y) * (1 - y)    // peaks at 1/3
        let highlightBump = 6.75 * y * y * (1 - y)       // peaks at 2/3
        y = clamp(y + 0.12 * shadows * shadowBump + 0.12 * highlights * highlightBump)

        let s = y * y * (3 - 2 * y)
        let k = contrast > 0 ? 0.75 * contrast : 0.6 * contrast
        return clamp(y + k * (s - y))
    }

    /// RGBA float cube (red changes fastest), for CIColorCubeWithColorSpace.
    func cubeData(dimension n: Int) -> Data {
        var values = [Float](repeating: 0, count: n * n * n * 4)
        let step = 1 / Double(n - 1)
        var i = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let (ro, go, bo) = apply(Double(r) * step, Double(g) * step, Double(b) * step)
                    values[i] = Float(ro)
                    values[i + 1] = Float(go)
                    values[i + 2] = Float(bo)
                    values[i + 3] = 1
                    i += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func apply(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let mapped = map(luma)
        // Bright/mid tones: scale RGB (keeps colour). Deep shadows: add the
        // difference instead, so lifted blacks don't blow up noise colours.
        let additive = (r + mapped - luma, g + mapped - luma, b + mapped - luma)
        guard luma > 1e-5 else { return (clamp(additive.0), clamp(additive.1), clamp(additive.2)) }
        let ratio = mapped / luma
        let scaled = (r * ratio, g * ratio, b * ratio)
        let w = smoothstep(0, 0.15, luma)
        return (clamp(w * scaled.0 + (1 - w) * additive.0),
                clamp(w * scaled.1 + (1 - w) * additive.1),
                clamp(w * scaled.2 + (1 - w) * additive.2))
    }

    private func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = clamp((x - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }
}

/// Rebuilds the tone cube only when a tone slider changed.
/// Not thread-safe: one instance per render queue / task.
final class ToneCubeCache {
    static let dimension = 33

    private var key: [Double]?
    private var filter: (CIFilter & CIColorCubeWithColorSpace)?

    func filter(for settings: DevelopSettings) -> (CIFilter & CIColorCubeWithColorSpace)? {
        let newKey = [settings.contrast, settings.highlights, settings.shadows, settings.whites, settings.blacks]
        guard newKey.contains(where: { $0 != 0 }) else { return nil }
        if let filter, key == newKey { return filter }
        let cube = filter ?? CIFilter.colorCubeWithColorSpace()
        cube.cubeDimension = Float(Self.dimension)
        cube.cubeData = ToneCurve(settings).cubeData(dimension: Self.dimension)
        cube.colorSpace = DevelopRenderer.sRGB
        filter = cube
        key = newKey
        return cube
    }
}
