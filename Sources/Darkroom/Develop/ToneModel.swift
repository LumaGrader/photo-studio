import Foundation
import CoreImage

/// Global tone sliders (Exposure, Contrast, Whites, Blacks) as one tone curve, measured on
/// Lightroom with the calibration kit (tools/calibration). The develop kernel applies the
/// curve hue-preserving on ProPhoto RGB channels, the way Lightroom's tone controls behave
/// (they also raise saturation as contrast goes up, so no separate saturation boost).
///
/// Order: Exposure → Blacks → Whites → Contrast. Tables: ToneModelData.swift (generated).
enum ToneModel {
    enum Slider: Hashable { case contrast, whites, blacks }

    /// Curve offsets measured at a few slider amounts; amounts in between are interpolated.
    struct SliderTable {
        let amounts: [Double]
        let offsets: [[Double]]

        /// Offset (output − input) at display value `x` (0…1) for `amount`.
        func offset(at x: Double, amount: Double) -> Double {
            guard amount != 0, let first = amounts.first, let last = amounts.last else { return 0 }
            let a = min(max(amount, first), last)
            var i = 0
            while i < amounts.count - 2 && a > amounts[i + 1] { i += 1 }
            let span = amounts[i + 1] - amounts[i]
            let t = span > 0 ? (a - amounts[i]) / span : 0
            return ToneModel.sample(offsets[i], at: x) * (1 - t) + ToneModel.sample(offsets[i + 1], at: x) * t
        }
    }

    /// Entries in the curve table handed to the kernel (inputs 0…1; above 1 is extrapolated).
    static let lutSize = 1024

    static func isActive(_ s: DevelopSettings) -> Bool {
        s.exposure != 0 || s.contrast != 0 || s.whites != 0 || s.blacks != 0
    }

    /// Display value (sRGB-encoded, 0…1) in → out for the current slider values.
    static func value(_ x: Double, settings s: DevelopSettings) -> Double {
        var v = exposure(min(max(x, 0), 1), ev: s.exposure)
        for (slider, amount) in [(Slider.blacks, s.blacks), (.whites, s.whites), (.contrast, s.contrast)]
        where amount != 0 {
            if let table = sliderTables[slider] {
                v += table.offset(at: min(max(v, 0), 1), amount: amount)
            }
        }
        return min(max(v, 0), 1)
    }

    /// Exposure on a rendered photo: back to scene light, × 2^EV, rendered again.
    static func exposure(_ x: Double, ev: Double) -> Double {
        guard ev != 0 else { return x }
        let stops = interpolate(x, xs: exposureCurve, ys: exposureStops) + ev
        return interpolate(stops, xs: exposureStops, ys: exposureCurve)
    }

    /// The curve as a `lutSize` × 1 table image (value in every channel).
    static func lutImage(_ s: DevelopSettings) -> CIImage {
        var values = [Float](repeating: 0, count: lutSize * 4)
        for i in 0..<lutSize {
            let v = Float(value(Double(i) / Double(lutSize - 1), settings: s))
            values[i * 4] = v
            values[i * 4 + 1] = v
            values[i * 4 + 2] = v
            values[i * 4 + 3] = 1
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: lutSize * 16,
                       size: CGSize(width: lutSize, height: 1), format: .RGBAf, colorSpace: nil)
    }

    /// Identity table, used while the global sliders are all at 0.
    static let identityLUT: CIImage = lutImage(DevelopSettings())

    // MARK: - Helpers

    /// Linear interpolation of an evenly spaced table over 0…1.
    static func sample(_ table: [Double], at x: Double) -> Double {
        guard table.count > 1 else { return table.first ?? 0 }
        let p = min(max(x, 0), 1) * Double(table.count - 1)
        let i = min(Int(p), table.count - 2)
        let t = p - Double(i)
        return table[i] * (1 - t) + table[i + 1] * t
    }

    /// Piecewise-linear interpolation; `xs` ascending. Clamps outside the range.
    static func interpolate(_ x: Double, xs: [Double], ys: [Double]) -> Double {
        guard let first = xs.first, let last = xs.last else { return x }
        if x <= first { return ys[0] }
        if x >= last { return ys[ys.count - 1] }
        var lo = 0
        var hi = xs.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if xs[mid] <= x { lo = mid } else { hi = mid }
        }
        let span = xs[hi] - xs[lo]
        let t = span > 0 ? (x - xs[lo]) / span : 0
        return ys[lo] + (ys[hi] - ys[lo]) * t
    }
}
