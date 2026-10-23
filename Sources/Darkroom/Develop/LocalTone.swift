import Foundation
import CoreImage

/// Shadows and Highlights, measured on Lightroom with the calibration kit
/// (tools/calibration/fit_local.py). Each pixel gets a brightness gain (EV) looked up by its
/// zone value: a mix of the edge-aware local base (GuidedFilter) and the pixel itself.
/// Saturation follows less than a plain gain would (factor 2^(−β·gain)), as in Lightroom.
/// Tables: LocalToneData.swift (generated).
enum LocalTone {
    enum Slider: Hashable { case shadows, highlights }

    /// Entries in the zone table handed to the kernel, over `zoneRange`.
    static let tableSize = 256

    static func isActive(_ s: DevelopSettings) -> Bool {
        s.shadows != 0 || s.highlights != 0
    }

    /// Gain in EV for `amount` at zone value `v` (EV, 0 = white).
    static func gain(_ slider: Slider, amount: Double, at v: Double) -> Double {
        guard amount != 0, let table = tables[slider] else { return 0 }
        let x = (v - zoneRange.0) / (zoneRange.1 - zoneRange.0)
        return table.offset(at: x, amount: amount)
    }

    /// `tableSize` × 1 table: red = Shadows gain, green = Highlights gain.
    static func zoneImage(_ s: DevelopSettings) -> CIImage {
        var values = [Float](repeating: 0, count: tableSize * 4)
        for i in 0..<tableSize {
            let v = zoneRange.0 + (zoneRange.1 - zoneRange.0) * Double(i) / Double(tableSize - 1)
            values[i * 4] = Float(gain(.shadows, amount: s.shadows, at: v))
            values[i * 4 + 1] = Float(gain(.highlights, amount: s.highlights, at: v))
            values[i * 4 + 3] = 1
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: tableSize * 16,
                       size: CGSize(width: tableSize, height: 1), format: .RGBAf, colorSpace: nil)
    }

    /// No gain anywhere (used while Shadows and Highlights are 0).
    static let flatZones: CIImage = zoneImage(DevelopSettings())
}
