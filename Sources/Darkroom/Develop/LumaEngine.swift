import Foundation
import simd

/// CPU side of the LumaGrader engine (ported from lumagrader src/engine/tone.js and
/// color.js): values computed once per settings change and handed to the GPU kernel.
enum LumaEngine {

    // MARK: - Exposure highlight shoulder (tone.js)

    static let exposureKnee = 0.4

    /// Shoulder steepness `a` for +EV: slope 1 at the knee and the old white lands on white.
    /// Solves a / (1 − e^(−aT)) = 1 / (1 − k) by bisection. 0 = no shoulder.
    static func shoulderA(ev: Double) -> Double {
        let k = exposureKnee
        guard ev > 0 else { return 0 }
        let t = pow(2, ev) - k
        guard t > 1 - k else { return 0 }
        var lo = 1e-9
        var hi = 400.0
        for _ in 0..<80 {
            let m = (lo + hi) / 2
            if m / (1 - exp(-m * t)) > 1 / (1 - k) { hi = m } else { lo = m }
        }
        return (lo + hi) / 2
    }

    // MARK: - White balance for non-RAW files (color.js whiteBalanceMatrix)

    private static let refKelvin = 6504.0
    private static let warmMirror = 0.85

    private static let bradford = simd_double3x3(rows: [
        SIMD3(0.8951, 0.2664, -0.1614), SIMD3(-0.7502, 1.7135, 0.0367), SIMD3(0.0389, -0.0685, 1.0296)])
    private static let srgbToXYZ = simd_double3x3(rows: [
        SIMD3(0.4124564, 0.3575761, 0.1804375), SIMD3(0.2126729, 0.7151522, 0.072175), SIMD3(0.0193339, 0.119192, 0.9503041)])
    private static let xyzToSRGB = simd_double3x3(rows: [
        SIMD3(3.2404542, -1.5371385, -0.4985314), SIMD3(-0.969266, 1.8760108, 0.041556), SIMD3(0.0556434, -0.2040259, 1.0572252)])

    /// Relative Temp/Tint (-100…100) → 3×3 matrix on linear sRGB (rows), nil when neutral.
    /// Bradford adaptation from the assumed illuminant to D65, normalised so grey keeps luminance.
    static func whiteBalanceMatrix(temperature: Double, tint: Double) -> simd_double3x3? {
        let t = min(max(temperature, -100), 100)
        let n = min(max(tint, -100), 100)
        guard t != 0 || n != 0 else { return nil }
        let coolT = t > 0 ? -warmMirror * t : t
        let destination = xyToXYZ(illuminantXY(kelvin: refKelvin, duv: 0))
        var m: simd_double3x3
        if t > 0 {
            let coolOnly = adaptMatrix(from: xyToXYZ(illuminantXY(kelvin: tempToKelvin(coolT), duv: 0)), to: destination)
            let tintOnly = n != 0
                ? adaptMatrix(from: xyToXYZ(illuminantXY(kelvin: refKelvin, duv: n / 100 * 0.03)), to: destination)
                : matrix_identity_double3x3
            m = coolOnly.inverse * tintOnly
        } else {
            m = adaptMatrix(from: xyToXYZ(illuminantXY(kelvin: tempToKelvin(coolT), duv: n / 100 * 0.03)), to: destination)
        }
        let grey = m * SIMD3<Double>(1, 1, 1)
        let luma = 0.2126 * grey.x + 0.7152 * grey.y + 0.0722 * grey.z
        return m * (1 / luma)
    }

    private static func tempToKelvin(_ temp: Double) -> Double {
        1e6 / (1e6 / refKelvin - 1.3 * min(max(temp, -100), 100))
    }

    /// CIE xy of a black-body radiator (Kim et al. cubic spline, 1667–25000 K).
    private static func planckXY(_ kelvin: Double) -> SIMD2<Double> {
        let t = min(max(kelvin, 1667), 25000)
        let t1 = 1e3 / t, t2 = t1 * t1, t3 = t2 * t1
        let x = t <= 4000
            ? -0.2661239 * t3 - 0.2343589 * t2 + 0.8776956 * t1 + 0.17991
            : -3.0258469 * t3 + 2.1070379 * t2 + 0.2226347 * t1 + 0.24039
        let x2 = x * x, x3 = x2 * x
        let y: Double
        if t <= 2222 {
            y = -1.1063814 * x3 - 1.3481102 * x2 + 2.18555832 * x - 0.20219683
        } else if t <= 4000 {
            y = -0.9549476 * x3 - 1.37418593 * x2 + 2.09137015 * x - 0.16748867
        } else {
            y = 3.081758 * x3 - 5.8733867 * x2 + 3.75112997 * x - 0.37001483
        }
        return SIMD2(x, y)
    }

    private static func xyToUV(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let d = -2 * p.x + 12 * p.y + 3
        return SIMD2(4 * p.x / d, 6 * p.y / d)
    }

    private static func uvToXY(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let d = 2 * p.x - 8 * p.y + 4
        return SIMD2(3 * p.x / d, 2 * p.y / d)
    }

    /// Illuminant chromaticity for a temperature and a Duv offset (+ = greener light).
    private static func illuminantXY(kelvin: Double, duv: Double) -> SIMD2<Double> {
        let uv = xyToUV(planckXY(kelvin))
        guard duv != 0 else { return uvToXY(uv) }
        let a = xyToUV(planckXY(kelvin * 0.995))
        let b = xyToUV(planckXY(kelvin * 1.005))
        var normal = SIMD2(-(b.y - a.y), b.x - a.x)
        let length = simd_length(normal)
        normal = length > 0 ? normal / length : SIMD2(0, 1)
        if normal.y < 0 { normal = -normal }
        return uvToXY(uv + normal * duv)
    }

    private static func xyToXYZ(_ p: SIMD2<Double>) -> SIMD3<Double> {
        SIMD3(p.x / p.y, 1, (1 - p.x - p.y) / p.y)
    }

    private static func adaptMatrix(from source: SIMD3<Double>, to destination: SIMD3<Double>) -> simd_double3x3 {
        let cs = bradford * source
        let cd = bradford * destination
        let scale = simd_double3x3(diagonal: SIMD3(cd.x / cs.x, cd.y / cs.y, cd.z / cs.z))
        return xyzToSRGB * bradford.inverse * scale * bradford * srgbToXYZ
    }

    // MARK: - Color grading (color.js gradeUniforms / hueDirection)

    static let gradeChroma = 0.105 // Oklab chroma offset at Saturation 100 (fitted to Lightroom; was 0.06)
    static let gradeLuminance = 0.07 // Oklab lightness shift at Luminance ±100

    private static let prophotoToSRGB = simd_double3x3(rows: [
        SIMD3(2.034076, -0.727334, -0.306742), SIMD3(-0.228813, 1.23173, -0.002917), SIMD3(-0.00857, -0.153287, 1.161856)])

    struct GradeUniforms {
        /// (a, b) offsets for shadows, midtones, highlights, global.
        var tints: [SIMD2<Double>]
        var luminances: [Double]
        var blending: Double
        var balance: Double
    }

    static func gradeUniforms(_ grade: ColorGrade) -> GradeUniforms {
        let wheels = [grade.shadows, grade.midtones, grade.highlights, grade.global]
        let tints = wheels.map { wheel -> SIMD2<Double> in
            let amount = min(max(wheel.saturation, 0), 100) / 100 * gradeChroma
            return hueDirection(wheel.hue) * amount
        }
        let lums = wheels.map { min(max($0.luminance, -100), 100) / 100 * gradeLuminance }
        return GradeUniforms(
            tints: tints,
            luminances: lums,
            blending: min(max(grade.blending, 0), 100) / 100,
            balance: min(max(grade.balance, -100), 100) / 100)
    }

    /// Unit Oklab (a, b) direction of a wheel hue, as Lightroom's wide-gamut wheel
    /// (HSV(h, 0.8, 1) in ProPhoto primaries, gamma 1.3).
    static func hueDirection(_ hue: Double) -> SIMD2<Double> {
        let rgb = hsvRGB(hue: hue)
        let prophoto = SIMD3(rgb.x, rgb.y, rgb.z).map { pow(1 - 0.8 * (1 - $0), 1.3) }
        let linear = prophotoToSRGB * prophoto
        let lab = linearToOklab(linear)
        let direction = SIMD2(lab.y, lab.z)
        let length = simd_length(direction)
        return length > 0 ? direction / length : SIMD2(1, 0)
    }

    /// HSV(h, 1, 1) → RGB.
    private static func hsvRGB(hue: Double) -> SIMD3<Double> {
        let hp = ((hue.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = 1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1)
        switch hp {
        case ..<1: return SIMD3(1, x, 0)
        case ..<2: return SIMD3(x, 1, 0)
        case ..<3: return SIMD3(0, 1, x)
        case ..<4: return SIMD3(0, x, 1)
        case ..<5: return SIMD3(x, 0, 1)
        default: return SIMD3(1, 0, x)
        }
    }

    private static func linearToOklab(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let l = cbrt(0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z)
        let m = cbrt(0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z)
        let s = cbrt(0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z)
        return SIMD3(
            0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s)
    }
}

private extension SIMD3 where Scalar == Double {
    func map(_ transform: (Double) -> Double) -> SIMD3<Double> {
        SIMD3(transform(x), transform(y), transform(z))
    }
}
