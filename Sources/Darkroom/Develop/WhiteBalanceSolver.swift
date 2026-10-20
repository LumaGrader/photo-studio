import Foundation
import CoreImage
import simd

/// Finds the Temp/Tint that make an area neutral grey (white balance picker, Auto WB).
/// RAW: asks the macOS RAW decoder for the area's average colour at trial settings.
/// Other files: works on the area's colour with the same Bradford matrix the kernel uses.
enum WhiteBalanceSolver {
    struct Result {
        let temperature: Double
        let tint: Double
    }

    /// `point`: 0…1 from the top-left of the developed (cropped) photo; nil = whole photo (Auto).
    static func solve(source: DevelopSource, crop: CropSettings, point: CGPoint?,
                      current: (temperature: Double?, tint: Double?)) -> Result? {
        switch source.kind {
        case let .raw(filter, asShotTemperature, asShotTint):
            guard let extent = filter.outputImage?.extent, !extent.isInfinite else { return nil }
            let region = sampleRegion(point: point, crop: crop, extent: extent)
            let start = SIMD2(1e6 / (current.temperature ?? asShotTemperature), current.tint ?? asShotTint)
            let solved = newton(
                start: start, step: SIMD2(8, 4),
                lower: SIMD2(1e6 / 50000, -150), upper: SIMD2(1e6 / 2000, 150)
            ) { x -> SIMD3<Double>? in
                filter.neutralTemperature = Float(1e6 / x.x)
                filter.neutralTint = Float(x.y)
                guard let output = filter.outputImage else { return nil }
                return average(output, in: region)
            }
            guard let solved else { return nil }
            let kelvin = 1e6 / solved.x
            let step: Double = kelvin < 10000 ? 50 : 100
            return Result(temperature: (kelvin / step).rounded() * step, tint: solved.y.rounded())

        case let .image(image):
            let region = sampleRegion(point: point, crop: crop, extent: image.extent)
            guard let base = average(image, in: region) else { return nil }
            let solved = newton(
                start: SIMD2(current.temperature ?? 0, current.tint ?? 0), step: SIMD2(5, 5),
                lower: SIMD2(-100, -100), upper: SIMD2(100, 100)
            ) { x -> SIMD3<Double>? in
                guard let m = LumaEngine.whiteBalanceMatrix(temperature: x.x, tint: x.y) else { return base }
                return m * base
            }
            guard let solved else { return nil }
            return Result(temperature: solved.x.rounded(), tint: solved.y.rounded())
        }
    }

    // MARK: - Private

    /// Area to average, in the source image's coordinates.
    private static func sampleRegion(point: CGPoint?, crop: CropSettings, extent: CGRect) -> CGRect {
        guard let point else { return extent }
        let p = DevelopRenderer.sourcePoint(normalized: point, crop: crop, sourceExtent: extent)
        let side = max(4, 0.006 * max(extent.width, extent.height))
        return CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side)
            .intersection(extent)
    }

    private static func average(_ image: CIImage, in region: CGRect) -> SIMD3<Double>? {
        guard !region.isEmpty else { return nil }
        let averaged = image.cropped(to: region)
            .applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: region)])
        var pixel = [Float](repeating: 0, count: 4)
        DevelopRenderer.context.render(
            averaged, toBitmap: &pixel, rowBytes: 16,
            bounds: CGRect(x: averaged.extent.minX, y: averaged.extent.minY, width: 1, height: 1),
            format: .RGBAf, colorSpace: nil)
        let c = SIMD3<Double>(Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
        return c.x > 1e-6 && c.y > 1e-6 && c.z > 1e-6 ? c : nil
    }

    /// Distance from neutral: blue–yellow and green–magenta (log ratios).
    private static func error(_ c: SIMD3<Double>) -> SIMD2<Double> {
        SIMD2(log(c.z / c.x), log(c.y / (c.x * c.z).squareRoot()))
    }

    /// 2-D Newton steps with a numerical Jacobian.
    private static func newton(start: SIMD2<Double>, step: SIMD2<Double>,
                               lower: SIMD2<Double>, upper: SIMD2<Double>,
                               probe: (SIMD2<Double>) -> SIMD3<Double>?) -> SIMD2<Double>? {
        var x = simd_clamp(start, lower, upper)
        for _ in 0..<7 {
            guard let c0 = probe(x) else { return nil }
            let e0 = error(c0)
            if simd_length(e0) < 0.004 { break }
            guard let ca = probe(x + SIMD2(step.x, 0)), let cb = probe(x + SIMD2(0, step.y)) else { return nil }
            let jacobian = simd_double2x2((error(ca) - e0) / step.x, (error(cb) - e0) / step.y)
            guard abs(jacobian.determinant) > 1e-12 else { break }
            var delta = -(jacobian.inverse * e0)
            // Don't jump too far in one go.
            let limit = (upper - lower) * 0.35
            delta = simd_clamp(delta, -limit, limit)
            x = simd_clamp(x + delta, lower, upper)
        }
        return x
    }
}
