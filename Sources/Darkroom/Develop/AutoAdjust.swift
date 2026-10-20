import Foundation

/// Auto Tone / Auto White Balance for photos that aren't open in Develop (batch Auto, ⌘U on
/// a Grid selection). Same maths as the Develop session's Auto buttons, on a 1024 px decode.
enum AutoAdjust {
    struct Result {
        /// Exposure, Contrast, Highlights, Shadows, Whites, Blacks.
        var tone: [Double]?
        var whiteBalance: (temperature: Double, tint: Double)?

        func apply(to s: inout DevelopSettings) {
            if let wb = whiteBalance {
                s.temperature = wb.temperature
                s.tint = wb.tint
            }
            if let t = tone, t.count == 6 {
                s.exposure = t[0]
                s.contrast = t[1]
                s.highlights = t[2]
                s.shadows = t[3]
                s.whites = t[4]
                s.blacks = t[5]
            }
        }
    }

    /// Runs off the main thread (decodes the photo).
    static func compute(url: URL, settings: DevelopSettings, tone: Bool, whiteBalance: Bool) -> Result? {
        guard let source = DevelopRenderer.makeSource(url: url, maxPixel: 1024) else { return nil }
        var result = Result()
        var s = settings
        if whiteBalance,
           let wb = WhiteBalanceSolver.solve(source: source, crop: s.crop, point: nil,
                                             current: (s.temperature, s.tint)) {
            result.whiteBalance = (wb.temperature, wb.tint)
            s.temperature = wb.temperature
            s.tint = wb.tint
        }
        if tone {
            var probe = s
            probe.exposure = 0
            probe.contrast = 0
            probe.highlights = 0
            probe.shadows = 0
            probe.whites = 0
            probe.blacks = 0
            probe.curve = ToneCurvePoints()
            if let image = DevelopRenderer.cgImage(from: source, settings: probe, cube: ToneCubeCache()),
               let p = ImageSampler.lumaPercentiles(image, [0.005, 0.05, 0.5, 0.95, 0.995]) {
                result.tone = DevelopSession.autoToneValues(p)
            }
        }
        guard result.tone != nil || result.whiteBalance != nil else { return nil }
        return result
    }
}
