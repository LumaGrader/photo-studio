import Foundation
import CoreImage

/// Color Mixer (HSL), measured on Lightroom (tools/calibration/fit_hsl.py). Each band moves
/// a pixel's Oklab hue, chroma and lightness by amounts that depend on the pixel's own
/// hue and chroma; values scale linearly from the ±50 measurements. The kernel looks the
/// combined effect up in a hue × chroma table. Tables: HSLModelData.swift (generated).
enum HSLModel {
    /// Table handed to the kernel: one column per degree (0…360, 360 = 0) and `tableRows`
    /// chroma rows over 0…`maxChroma`; red = hue shift (°), green = ln chroma ratio,
    /// blue = ln lightness ratio.
    static let tableWidth = 361
    static let tableRows = 16
    static let maxChroma = 0.30

    private static let bandCount = 8
    private static let effects = 3

    /// [band][side][slider][effect][chroma row][hue bin].
    private static let data: [Float] = {
        guard let bytes = Data(base64Encoded: encoded) else { return [] }
        return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }()

    private static var rows: Int { chromaEdges.count - 1 }

    private static func value(band: Int, side: Int, slider: Int, effect: Int, row: Int, bin: Int) -> Double {
        let index = ((((band * 2 + side) * 3 + slider) * effects + effect) * rows + row) * hueBins + bin
        return index < data.count ? Double(data[index]) : 0
    }

    /// Measured effect at `hue` (degrees, bins centred at 2.5° + 5°·i, wrapping round).
    private static func atHue(band: Int, side: Int, slider: Int, effect: Int, row: Int, hue: Double) -> Double {
        let p = (hue - 2.5) / 5
        let i0 = Int(floor(p))
        let t = p - Double(i0)
        let a = ((i0 % hueBins) + hueBins) % hueBins
        let b = (a + 1) % hueBins
        return value(band: band, side: side, slider: slider, effect: effect, row: row, bin: a) * (1 - t)
            + value(band: band, side: side, slider: slider, effect: effect, row: row, bin: b) * t
    }

    static func tableImage(_ s: DevelopSettings) -> CIImage {
        let sliders = [s.hslHue, s.hslSaturation, s.hslLuminance]
        let centres = (0..<rows).map { (chromaEdges[$0] + chromaEdges[$0 + 1]) / 2 }
        var values = [Float](repeating: 0, count: tableWidth * tableRows * 4)
        for r in 0..<tableRows {
            let chroma = maxChroma * Double(r) / Double(tableRows - 1)
            // Position between measured chroma rows (clamped at both ends).
            var r0 = 0
            while r0 < rows - 2 && chroma > centres[r0 + 1] { r0 += 1 }
            let span = centres[r0 + 1] - centres[r0]
            let t = min(max((chroma - centres[r0]) / span, 0), 1)
            for column in 0..<tableWidth {
                let hue = Double(column % 360)
                var effect = [0.0, 0.0, 0.0]
                for (slider, bands) in sliders.enumerated() {
                    for band in 0..<min(bandCount, bands.count) where bands[band] != 0 {
                        let side = bands[band] > 0 ? 1 : 0
                        let scale = min(abs(bands[band]), 100) / 50
                        for e in 0..<effects {
                            let a = atHue(band: band, side: side, slider: slider, effect: e, row: r0, hue: hue)
                            let b = atHue(band: band, side: side, slider: slider, effect: e, row: r0 + 1, hue: hue)
                            effect[e] += (a * (1 - t) + b * t) * scale
                        }
                    }
                }
                // CIImage(bitmapData:) puts the first row at the top (highest y), so chroma
                // row r goes to memory row (tableRows − 1 − r): the kernel's y grows with chroma.
                let i = ((tableRows - 1 - r) * tableWidth + column) * 4
                values[i] = Float(effect[0])
                values[i + 1] = Float(effect[1])
                values[i + 2] = Float(effect[2])
                values[i + 3] = 1
            }
        }
        let bytes = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: bytes, bytesPerRow: tableWidth * 16,
                       size: CGSize(width: tableWidth, height: tableRows), format: .RGBAf, colorSpace: nil)
    }

    /// All zero (used while the Color Mixer is untouched).
    static let flatTable: CIImage = tableImage(DevelopSettings())
}
