import Foundation
import simd

/// Calibration (red/green/blue primary hue and saturation) and the global Saturation slider
/// as 3×3 matrices on linear RGB, measured on Lightroom (tools/calibration/fit_color.py).
/// Applied right after white balance, before tone. Tables: ColorCalibrationData.swift.
enum ColorCalibration {
    enum Slider: CaseIterable {
        case redHue, redSaturation, greenHue, greenSaturation, blueHue, blueSaturation, saturation
    }

    struct Measured {
        let slider: Slider
        /// Slider value the matrix was measured at (sign = side).
        let amount: Double
        /// Matrix − identity, rows (each row sums to 0, so white stays white).
        let d: [[Double]]
    }

    static func isActive(_ cal: CalibrationSettings, saturation: Double) -> Bool {
        !cal.isNeutral || saturation != 0
    }

    /// Product of the per-slider matrices (identity when everything is 0).
    static func matrix(_ cal: CalibrationSettings, saturation: Double) -> simd_double3x3 {
        let values: [(Slider, Double)] = [
            (.redHue, cal.redHue), (.redSaturation, cal.redSaturation),
            (.greenHue, cal.greenHue), (.greenSaturation, cal.greenSaturation),
            (.blueHue, cal.blueHue), (.blueSaturation, cal.blueSaturation),
            (.saturation, saturation),
        ]
        var m = matrix_identity_double3x3
        for (slider, value) in values where value != 0 {
            m = single(slider, value) * m
        }
        return m
    }

    /// I + D · value / amount, using the measurement on the same side (+/−) as `value`.
    static func single(_ slider: Slider, _ value: Double) -> simd_double3x3 {
        guard let entry = measured.first(where: { $0.slider == slider && ($0.amount > 0) == (value > 0) })
        else { return matrix_identity_double3x3 }
        let t = min(max(value, -100), 100) / entry.amount
        let rows = (0..<3).map { r in
            SIMD3<Double>((0..<3).map { c in (r == c ? 1 : 0) + entry.d[r][c] * t })
        }
        return simd_double3x3(rows: rows)
    }
}
