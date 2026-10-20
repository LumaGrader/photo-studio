import Foundation
import CoreGraphics
import simd

/// Oklab ↔ linear sRGB (same constants as the Metal kernel).
enum Oklab {
    static func fromLinear(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let l = 0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z
        let m = 0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z
        let s = 0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z
        let l3 = cbrt(l), m3 = cbrt(m), s3 = cbrt(s)
        return SIMD3(
            0.2104542553 * l3 + 0.7936177850 * m3 - 0.0040720468 * s3,
            1.9779984951 * l3 - 2.4285922050 * m3 + 0.4505937099 * s3,
            0.0259040371 * l3 + 0.7827717662 * m3 - 0.8086757660 * s3)
    }

    static func toLinear(_ o: SIMD3<Double>) -> SIMD3<Double> {
        let l = o.x + 0.3963377774 * o.y + 0.2158037573 * o.z
        let m = o.x - 0.1055613458 * o.y - 0.0638541728 * o.z
        let s = o.x - 0.0894841775 * o.y - 1.2914855480 * o.z
        let l3 = l * l * l, m3 = m * m * m, s3 = s * s * s
        return SIMD3(
            4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
            -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
            -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3)
    }

    /// (L, chroma, hue in degrees) of an sRGB-encoded colour.
    static func lch(encoded c: SIMD3<Double>) -> (l: Double, c: Double, h: Double) {
        let o = fromLinear(SRGB.decode(c))
        var h = atan2(o.z, o.y) * 180 / .pi
        if h < 0 { h += 360 }
        return (o.x, (o.y * o.y + o.z * o.z).squareRoot(), h)
    }
}

enum SRGB {
    static func decode(_ v: Double) -> Double {
        let v = max(v, 0)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    static func encode(_ v: Double) -> Double {
        let v = max(v, 0)
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    static func decode(_ c: SIMD3<Double>) -> SIMD3<Double> { SIMD3(decode(c.x), decode(c.y), decode(c.z)) }

    /// HSV hue (degrees) and saturation, as used by the Color Mixer bands.
    static func hueSaturation(_ c: SIMD3<Double>) -> (hue: Double, saturation: Double) {
        let mx = max(c.x, c.y, c.z), mn = min(c.x, c.y, c.z)
        let ch = mx - mn
        guard ch > 1e-6 else { return (0, 0) }
        var h: Double
        if mx == c.x { h = ((c.y - c.z) / ch).truncatingRemainder(dividingBy: 6) }
        else if mx == c.y { h = (c.z - c.x) / ch + 2 }
        else { h = (c.x - c.y) / ch + 4 }
        h *= 60
        if h < 0 { h += 360 }
        return (h, mx > 0 ? ch / mx : 0)
    }

    /// Color Mixer band centres (Red … Magenta, then Red again at 360°).
    static let bandCentres: [Double] = [0, 30, 60, 120, 180, 240, 275, 320, 360]

    /// How much each of the 8 bands owns a hue (two neighbouring bands share it).
    static func bandWeights(hue: Double) -> [Double] {
        var weights = [Double](repeating: 0, count: 8)
        var i0 = 7
        for i in 0..<8 where hue >= bandCentres[i] && hue < bandCentres[i + 1] { i0 = i }
        let t = (hue - bandCentres[i0]) / (bandCentres[i0 + 1] - bandCentres[i0])
        let i1 = i0 == 7 ? 0 : i0 + 1
        weights[i0] += 1 - t
        weights[i1] += t
        return weights
    }
}

/// Reads colours out of a rendered CGImage (for the colour pickers).
enum ImageSampler {
    /// Average sRGB-encoded colour (0…1) around a point given as 0…1 from the top-left.
    static func average(_ image: CGImage, at point: CGPoint, radius: Int = 3) -> SIMD3<Double>? {
        let x = Int((point.x * CGFloat(image.width)).rounded(.down))
        let y = Int((point.y * CGFloat(image.height)).rounded(.down))
        let rect = CGRect(x: x - radius, y: y - radius, width: 2 * radius + 1, height: 2 * radius + 1)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isEmpty, let patch = image.cropping(to: rect) else { return nil }
        let w = patch.width, h = patch.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(patch, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = SIMD3<Double>(0, 0, 0)
        for i in 0..<(w * h) {
            sum += SIMD3(Double(pixels[i * 4]), Double(pixels[i * 4 + 1]), Double(pixels[i * 4 + 2]))
        }
        return sum / Double(w * h * 255)
    }

    /// Luminance (sRGB-encoded) percentiles of an image, for Auto tone.
    static func lumaPercentiles(_ image: CGImage, _ fractions: [Double], maxSide: Int = 512) -> [Double]? {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var histogram = [Int](repeating: 0, count: 256)
        for i in 0..<(w * h) {
            let r = SRGB.decode(Double(pixels[i * 4]) / 255)
            let g = SRGB.decode(Double(pixels[i * 4 + 1]) / 255)
            let b = SRGB.decode(Double(pixels[i * 4 + 2]) / 255)
            let luma = SRGB.encode(0.2126 * r + 0.7152 * g + 0.0722 * b)
            histogram[min(255, Int(luma * 255 + 0.5))] += 1
        }
        let total = Double(w * h)
        return fractions.map { fraction in
            var count = 0
            for (i, n) in histogram.enumerated() {
                count += n
                if Double(count) >= fraction * total { return Double(i) / 255 }
            }
            return 1
        }
    }
}
