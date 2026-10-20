import SwiftUI
import CoreGraphics

struct HistogramData: Equatable {
    var red: [Float]
    var green: [Float]
    var blue: [Float]
    /// Share of pixels clipped to black / white (any channel at 0 / 255).
    var clippedShadows: Double
    var clippedHighlights: Double

    /// RGB histogram of a (downscaled) image, normalised so the tallest inner bin is 1.
    static func compute(_ image: CGImage) -> HistogramData? {
        let width = 256
        let height = max(1, Int(Double(image.height) * Double(width) / Double(max(image.width, 1))))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var r = [Float](repeating: 0, count: 256)
        var g = [Float](repeating: 0, count: 256)
        var b = [Float](repeating: 0, count: 256)
        var low = 0, high = 0
        let count = width * height
        for i in 0..<count {
            let pr = Int(pixels[i * 4]), pg = Int(pixels[i * 4 + 1]), pb = Int(pixels[i * 4 + 2])
            r[pr] += 1
            g[pg] += 1
            b[pb] += 1
            if pr == 0 || pg == 0 || pb == 0 { low += 1 }
            if pr == 255 || pg == 255 || pb == 255 { high += 1 }
        }
        let peak = max(1, (1..<255).map { max(r[$0], g[$0], b[$0]) }.max() ?? 1)
        func normalise(_ bins: [Float]) -> [Float] { bins.map { min(1, $0 / peak) } }
        return HistogramData(
            red: normalise(r), green: normalise(g), blue: normalise(b),
            clippedShadows: Double(low) / Double(count),
            clippedHighlights: Double(high) / Double(count))
    }
}

struct HistogramView: View {
    let data: HistogramData?

    var body: some View {
        ZStack(alignment: .top) {
            Canvas { context, size in
                guard let data else { return }
                context.blendMode = .plusLighter
                draw(data.red, color: Color(red: 0.9, green: 0.2, blue: 0.2), in: size, context: &context)
                draw(data.green, color: Color(red: 0.2, green: 0.8, blue: 0.3), in: size, context: &context)
                draw(data.blue, color: Color(red: 0.25, green: 0.4, blue: 1.0), in: size, context: &context)
            }
            HStack {
                clipBadge(data?.clippedShadows ?? 0, help: "Clipped shadows")
                Spacer()
                clipBadge(data?.clippedHighlights ?? 0, help: "Clipped highlights")
            }
            .padding(4)
        }
        .frame(height: 90)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    private func draw(_ bins: [Float], color: Color, in size: CGSize, context: inout GraphicsContext) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        for (i, value) in bins.enumerated() {
            let x = CGFloat(i) / 255 * size.width
            path.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(value) * 0.92)))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        context.fill(path, with: .color(color.opacity(0.6)))
    }

    private func clipBadge(_ fraction: Double, help: String) -> some View {
        Circle()
            .fill(fraction > 0.005 ? Color.white : Color.white.opacity(0.15))
            .frame(width: 7, height: 7)
            .help("\(help): \(String(format: "%.1f", fraction * 100))%")
    }
}
