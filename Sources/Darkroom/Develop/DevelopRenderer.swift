import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// The decoded photo that edits are applied to, plus its local-brightness map.
struct DevelopSource {
    enum Kind {
        /// Real RAW decode by macOS. White balance is applied inside the RAW decoder
        /// (As Shot values come from the camera); exposure and tone run in our kernel.
        case raw(CIRAWFilter, asShotTemperature: Double, asShotTint: Double)
        /// JPEG, HEIC, TIFF, PNG…
        case image(CIImage)
    }

    let kind: Kind
    /// Guided-filter coefficients for local Highlights/Shadows (nil = unavailable).
    let localBase: CIImage?
    /// The RAW decoder's own detail settings for this camera (sharpening, noise reduction).
    var rawDefaults = RawDetailDefaults()
    /// Long side of the photo at full resolution (before `maxPixel` scaling).
    var nativeLongSide: CGFloat = 0
    /// The photo file (used to cache its Select Subject mask).
    var url: URL?

    /// Identity of this decode (preview and full-size sources differ), for caches.
    var decoderID: String {
        switch kind {
        case let .raw(filter, _, _): return "\(ObjectIdentifier(filter).hashValue)"
        case let .image(image): return "\(ObjectIdentifier(image).hashValue)"
        }
    }

    var isRaw: Bool {
        if case .raw = kind { return true }
        return false
    }

    var asShot: (temperature: Double, tint: Double)? {
        if case let .raw(_, temperature, tint) = kind { return (temperature, tint) }
        return nil
    }
}

/// What macOS's RAW decoder picks for a camera before we touch anything.
struct RawDetailDefaults {
    var sharpness: Float = 0.5
    var luminanceNoise: Float = 0
    var colorNoise: Float = 0.5
    var lensSupported = false
    var sharpnessSupported = true
    var luminanceNoiseSupported = true
    var colorNoiseSupported = true

    init() {}

    init(filter: CIRAWFilter) {
        sharpness = filter.sharpnessAmount
        luminanceNoise = filter.luminanceNoiseReductionAmount
        colorNoise = filter.colorNoiseReductionAmount
        lensSupported = filter.isLensCorrectionSupported
        sharpnessSupported = filter.isSharpnessSupported
        luminanceNoiseSupported = filter.isLuminanceNoiseReductionSupported
        colorNoiseSupported = filter.isColorNoiseReductionSupported
    }
}

/// Builds the Core Image pipeline for a photo + settings: decode → LumaGrader develop
/// kernel (tone, colour, HSL, grading). Falls back to a basic built-in-filter pipeline
/// if the kernel couldn't be compiled.
enum DevelopRenderer {
    static let context = CIContext()
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// `maxPixel` limits the long side (nil = full size).
    static func makeSource(url: URL, maxPixel: Int?) -> DevelopSource? {
        if FolderScanner.rawExtensions.contains(url.pathExtension.lowercased()),
           let filter = CIRAWFilter(imageURL: url) {
            let native = filter.nativeSize
            if let maxPixel, native.width > 0, native.height > 0 {
                let scale = min(1, CGFloat(maxPixel) / max(native.width, native.height))
                filter.scaleFactor = Float(scale)
            }
            let temperature = Double(filter.neutralTemperature)
            let tint = Double(filter.neutralTint)
            let defaults = RawDetailDefaults(filter: filter)
            filter.exposure = 0
            // Local-brightness map from the default rendering (Darkroom Color look).
            let base = filter.outputImage
                .map { baseLook($0, profile: .darkroomColor) }
                .flatMap { GuidedFilter.coefficientImage(for: $0, context: context) }
            return DevelopSource(
                kind: .raw(filter, asShotTemperature: temperature, asShotTint: tint),
                localBase: base,
                rawDefaults: defaults,
                nativeLongSide: max(native.width, native.height),
                url: url)
        }

        guard var image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        let nativeLongSide = max(image.extent.width, image.extent.height)
        if let maxPixel {
            let longSide = nativeLongSide
            if longSide > CGFloat(maxPixel) {
                let scale = CIFilter.lanczosScaleTransform()
                scale.inputImage = image
                scale.scale = Float(CGFloat(maxPixel) / longSide)
                scale.aspectRatio = 1
                if let output = scale.outputImage { image = output }
            }
        }
        // Move the origin to (0, 0) so every stage shares one simple coordinate frame.
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        return DevelopSource(kind: .image(image), localBase: GuidedFilter.coefficientImage(for: image, context: context),
                             nativeLongSide: nativeLongSide, url: url)
    }

    /// `includeCrop: false` shows the whole straightened frame (for the Crop tool).
    /// `overlayMask`: show that mask as a red overlay (Masking panel).
    static func apply(_ s: DevelopSettings, to source: DevelopSource, cube: ToneCubeCache,
                      includeCrop: Bool = true, overlayMask: UUID? = nil) -> CIImage? {
        guard var developed = develop(s, source: source, cube: cube) else { return nil }
        let kernels = try? DevelopKernel.shared.get()
        // Spot Removal first, so later adjustments treat the healed areas like the rest.
        if !s.spots.isEmpty {
            developed = RetouchRenderer.applySpots(s.spots, to: developed)
        }
        // Presence works on the whole frame (before crop), like Lightroom.
        if s.effects.presenceActive, let kernels {
            developed = DevelopKernel.applyPresence(kernels.combine, to: developed, effects: s.effects)
        }
        // Masks (local adjustments), still in the uncropped frame so they stay put.
        if !s.masks.isEmpty {
            developed = MaskRenderer.apply(s.masks, to: developed, url: source.url,
                                           overlay: overlayMask, presence: kernels?.combine)
        }
        if s.lensBlur.isActive {
            developed = RetouchRenderer.applyLensBlur(s.lensBlur, to: developed, url: source.url)
        }
        if !source.isRaw {
            developed = sharpen(developed, amount: s.detail.effectiveSharpening(isRaw: false))
        }
        var output = applyGeometry(developed, crop: s.crop, includeCrop: includeCrop)
        // Post-crop vignette + grain use the final frame.
        if s.effects.finishActive, let kernels {
            output = DevelopKernel.applyFinish(kernels.finish, to: output, effects: s.effects)
        }
        return output
    }

    // MARK: - Detail

    /// RAW: sharpening, noise reduction and lens corrections run inside the macOS decoder.
    /// Slider defaults (Sharpening 40, Color NR 25) equal the decoder's own defaults.
    private static func applyDetail(_ d: DetailSettings, to filter: CIRAWFilter, defaults: RawDetailDefaults) {
        if defaults.sharpnessSupported {
            let amount = d.effectiveSharpening(isRaw: true)
            let base = defaults.sharpness > 0.05 ? defaults.sharpness : 0.4
            filter.sharpnessAmount = min(base * Float(amount / DetailSettings.rawSharpening), 1)
        }
        if defaults.luminanceNoiseSupported {
            let nr = Float(min(max(d.noiseReduction, 0), 100) / 100)
            filter.luminanceNoiseReductionAmount = defaults.luminanceNoise + (1 - defaults.luminanceNoise) * nr
        }
        if defaults.colorNoiseSupported {
            let amount = d.colorNoise(isRaw: true)
            let base = defaults.colorNoise > 0.05 ? defaults.colorNoise : 0.4
            if amount <= DetailSettings.rawColorNoise {
                filter.colorNoiseReductionAmount = base * Float(amount / DetailSettings.rawColorNoise)
            } else {
                let extra = Float((amount - DetailSettings.rawColorNoise) / (100 - DetailSettings.rawColorNoise))
                filter.colorNoiseReductionAmount = base + (1 - base) * extra
            }
        }
        if defaults.lensSupported {
            filter.isLensCorrectionEnabled = d.lensOn(isRaw: true)
        }
    }

    /// JPEG/HEIC/TIFF noise reduction (before the develop kernel).
    private static func denoise(_ image: CIImage, detail d: DetailSettings) -> CIImage {
        let luminance = min(max(d.noiseReduction, 0), 100) / 100
        let color = min(max(d.colorNoise(isRaw: false), 0), 100) / 100
        guard luminance > 0 || color > 0 else { return image }
        var output = image
        if color > 0 {
            // Colour noise: blur chroma only, keep the original luminance.
            let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: 1 + 3 * color).cropped(to: image.extent)
            let blend = CIFilter.colorBlendMode()
            blend.inputImage = blurred
            blend.backgroundImage = image
            if let mixed = blend.outputImage?.cropped(to: image.extent) {
                output = mixed
            }
        }
        if luminance > 0 {
            let filter = CIFilter.noiseReduction()
            filter.inputImage = output
            filter.noiseLevel = Float(0.005 + 0.06 * luminance)
            filter.sharpness = Float(0.4 * (1 - luminance))
            output = filter.outputImage?.cropped(to: image.extent) ?? output
        }
        return output
    }

    /// JPEG/HEIC/TIFF sharpening (after tone + presence).
    private static func sharpen(_ image: CIImage, amount: Double) -> CIImage {
        guard amount > 0 else { return image }
        let longSide = max(image.extent.width, image.extent.height)
        let filter = CIFilter.sharpenLuminance()
        filter.inputImage = image
        filter.sharpness = Float(amount / 100)
        filter.radius = Float(max(0.6, 1.2 * longSide / 3000))
        return filter.outputImage?.cropped(to: image.extent) ?? image
    }

    private static func develop(_ s: DevelopSettings, source: DevelopSource, cube: ToneCubeCache) -> CIImage? {
        // Decode → denoise → profile only depends on these settings, so while other sliders
        // move it's kept as rendered pixels (BaseCache) and only the develop kernel re-runs.
        let baseKey = source.url.map {
            "\($0.path)|\(source.decoderID)|\(source.isRaw)|\(s.temperature ?? -1)|\(s.tint ?? -1)|\(s.effectiveProfile)|"
                + "\(s.lutProfile ?? "")|\(s.profileAmount)|\(s.detail)"
        }
        guard let image = BaseCache.shared.image(for: baseKey, build: { base(s, source: source) }) else { return nil }
        let extent = image.extent

        switch DevelopKernel.shared {
        case let .success(kernels):
            guard let output = DevelopKernel.apply(
                kernels.develop, to: image, settings: s, isRaw: source.isRaw, localBase: source.localBase)
            else { return nil }
            return output.cropped(to: extent)
        case .failure:
            return legacyPipeline(s, image: image, isRaw: source.isRaw, cube: cube)?.cropped(to: extent)
        }
    }

    /// The photo before the develop kernel: decode (RAW: white balance, detail, base look),
    /// noise reduction, Darkroom Denoise, profile.
    private static func base(_ s: DevelopSettings, source: DevelopSource) -> CIImage? {
        var image: CIImage
        switch source.kind {
        case let .raw(filter, asShotTemperature, asShotTint):
            filter.exposure = 0
            filter.neutralTemperature = Float(s.temperature ?? asShotTemperature)
            filter.neutralTint = Float(s.tint ?? asShotTint)
            applyDetail(s.detail, to: filter, defaults: source.rawDefaults)
            guard let output = filter.outputImage else { return nil }
            image = baseLook(output, profile: s.effectiveProfile)
        case let .image(base):
            image = denoise(base, detail: s.detail)
        }
        // Darkroom Denoise (edge-aware, on top of the decoder's own noise reduction).
        if s.detail.denoise > 0 {
            // Cached per photo + the settings that change the image before this step.
            let upstream = source.url.map {
                "\($0.path)|\(source.isRaw)|\(s.temperature ?? -1)|\(s.tint ?? -1)|\(s.effectiveProfile)|\(s.detail)"
            }
            image = RetouchRenderer.denoise(image, amount: s.detail.denoise, detail: s.detail.denoiseDetail,
                                            cacheKey: upstream)
        }
        // Darkroom looks and LUT profiles sit between the base rendering and the sliders.
        image = ProfileRenderer.apply(s, to: image)
        return image.cropped(to: image.extent)
    }

    /// RAW base rendering: the Darkroom Color look (also under the other Darkroom looks),
    /// or the macOS decode as is.
    private static func baseLook(_ image: CIImage, profile: RawProfile) -> CIImage {
        guard profile != .cameraNeutral, case let .success(kernels) = DevelopKernel.shared else { return image }
        return DevelopKernel.applyBaseLook(kernels.baseLook, to: image) ?? image
    }

    /// Size of the developed photo before geometry (only its shape matters to the crop tool).
    static func developedSize(of source: DevelopSource) -> CGSize? {
        switch source.kind {
        case let .raw(filter, _, _): return filter.outputImage?.extent.size
        case let .image(image): return image.extent.size
        }
    }

    // MARK: - Geometry (90° rotation → straighten → crop)

    static let cropBackground = CIColor(red: 0.07, green: 0.07, blue: 0.07)

    static func applyGeometry(_ image: CIImage, crop c: CropSettings, includeCrop: Bool) -> CIImage {
        guard !c.isDefault else { return image }
        let extent = image.extent
        let frame = c.frameSize(for: extent.size)
        let radians = -(Double(c.rotate90) + c.angle) * .pi / 180  // clockwise on screen
        let transform = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(radians)))
            .concatenating(CGAffineTransform(translationX: frame.width / 2, y: frame.height / 2))
        let turned = image.transformed(by: transform)
        let frameRect = CGRect(origin: .zero, size: frame)
        guard includeCrop else {
            let background = CIImage(color: cropBackground).cropped(to: frameRect)
            return turned.composited(over: background).cropped(to: frameRect)
        }
        // Crop rectangle: normalised, y from the top → Core Image (y up).
        let rect = CGRect(
            x: c.x * frame.width,
            y: (1 - c.y - c.height) * frame.height,
            width: c.width * frame.width,
            height: c.height * frame.height).integral.intersection(frameRect)
        guard !rect.isEmpty else { return turned.cropped(to: frameRect) }
        return turned.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    /// Inverse of the geometry: a point on the developed photo (0…1 from the top-left)
    /// → the same spot in the source image (Core Image coordinates).
    static func sourcePoint(normalized p: CGPoint, crop c: CropSettings, sourceExtent extent: CGRect) -> CGPoint {
        guard !c.isDefault else {
            return CGPoint(x: extent.minX + p.x * extent.width, y: extent.minY + (1 - p.y) * extent.height)
        }
        let frame = c.frameSize(for: extent.size)
        let radians = -(Double(c.rotate90) + c.angle) * .pi / 180
        let transform = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(radians)))
            .concatenating(CGAffineTransform(translationX: frame.width / 2, y: frame.height / 2))
        let rect = CGRect(x: c.x * frame.width, y: (1 - c.y - c.height) * frame.height,
                          width: c.width * frame.width, height: c.height * frame.height)
        let inFrame = CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + (1 - p.y) * rect.height)
        return inFrame.applying(transform.inverted())
    }

    static func cgImage(from source: DevelopSource, settings: DevelopSettings, cube: ToneCubeCache,
                        includeCrop: Bool = true, clipping: Bool = false, overlayMask: UUID? = nil) -> CGImage? {
        guard var output = apply(settings, to: source, cube: cube, includeCrop: includeCrop,
                                 overlayMask: overlayMask) else { return nil }
        if clipping, case let .success(kernels) = DevelopKernel.shared {
            output = DevelopKernel.applyClipping(kernels.clip, to: output)
        }
        let extent = output.extent.integral
        guard !extent.isEmpty, !extent.isInfinite else { return nil }
        return context.createCGImage(output, from: extent, format: .RGBA8, colorSpace: sRGB)
    }

    /// One-off render (thumbnails, loupe). Thread-safe: builds its own source.
    static func render(url: URL, settings: DevelopSettings, maxPixel: Int) -> CGImage? {
        guard let source = makeSource(url: url, maxPixel: maxPixel) else { return nil }
        return cgImage(from: source, settings: settings, cube: ToneCubeCache())
    }

    // MARK: - Fallback (only if the kernel failed to compile)

    private static func legacyPipeline(_ s: DevelopSettings, image input: CIImage, isRaw: Bool, cube: ToneCubeCache) -> CIImage? {
        var image = input
        if s.exposure != 0 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = image
            exposure.ev = Float(s.exposure)
            image = exposure.outputImage ?? image
        }
        if !isRaw, let wb = LumaEngine.whiteBalanceMatrix(temperature: s.temperature ?? 0, tint: s.tint ?? 0) {
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            matrix.rVector = CIVector(x: CGFloat(wb.columns.0[0]), y: CGFloat(wb.columns.1[0]), z: CGFloat(wb.columns.2[0]), w: 0)
            matrix.gVector = CIVector(x: CGFloat(wb.columns.0[1]), y: CGFloat(wb.columns.1[1]), z: CGFloat(wb.columns.2[1]), w: 0)
            matrix.bVector = CIVector(x: CGFloat(wb.columns.0[2]), y: CGFloat(wb.columns.1[2]), z: CGFloat(wb.columns.2[2]), w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            image = matrix.outputImage ?? image
        }
        if s.highlights < 0 || s.shadows > 0 {
            let local = CIFilter.highlightShadowAdjust()
            local.inputImage = image
            local.highlightAmount = Float(1 + 0.6 * min(s.highlights, 0) / 100)
            local.shadowAmount = Float(0.6 * max(s.shadows, 0) / 100)
            image = local.outputImage ?? image
        }
        if let tone = cube.filter(for: s) {
            tone.inputImage = image
            image = tone.outputImage ?? image
        }
        if s.vibrance != 0 {
            let vibrance = CIFilter.vibrance()
            vibrance.inputImage = image
            vibrance.amount = Float(s.vibrance / 100)
            image = vibrance.outputImage ?? image
        }
        if s.saturation != 0 {
            let color = CIFilter.colorControls()
            color.inputImage = image
            color.saturation = Float(1 + s.saturation / 100)
            color.brightness = 0
            color.contrast = 1
            image = color.outputImage ?? image
        }
        return image
    }
}
