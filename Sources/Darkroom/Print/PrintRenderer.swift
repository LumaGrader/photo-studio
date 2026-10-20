import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics

/// Renders a photo for the printer:
///   develop → turn (Rotate to Fit) → fit/fill to the print size → Print Adjustment →
///   print sharpening → 16-bit ProPhoto (ROMM RGB) → paper profile (the app manages colour).
///
/// The result is tagged with the paper profile, so the print system leaves it as it is when
/// the printer driver's own colour management is off. Without a profile it stays sRGB and the
/// printer manages colour.
enum PrintRenderer {
    private static let romm = CGColorSpace(name: CGColorSpace.rommrgb)!
    private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    /// Developed size of a photo in pixels (crop included), cheaply from a small render.
    static func developedSize(of photo: Photo) -> CGSize? {
        guard let source = DevelopRenderer.makeSource(url: photo.url, maxPixel: 1024),
              let image = DevelopRenderer.apply(photo.develop, to: source, cube: ToneCubeCache())
        else { return nil }
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, source.nativeLongSide > 0 else { return nil }
        // The source was decoded at most 1024 px long; scale back up to the file's size.
        let factor = source.nativeLongSide / min(1024, source.nativeLongSide)
        return CGSize(width: extent.width * factor, height: extent.height * factor)
    }

    /// The photo as it goes to the printer, `pixels` big.
    /// - Returns: a CGImage in the paper profile (or sRGB without one).
    static func render(_ photo: Photo, pixels: CGSize, layout: PrintPageLayout, settings s: PrintSettings) -> CGImage? {
        let width = Int(pixels.width), height = Int(pixels.height)
        guard width > 0, height > 0 else { return nil }
        // Decode only as big as needed (with some room for Fill cropping).
        let longest = Int(max(pixels.width, pixels.height) * (s.fit == .fill ? 1.6 : 1.1))
        guard let source = DevelopRenderer.makeSource(url: photo.url, maxPixel: longest),
              var image = DevelopRenderer.apply(photo.develop, to: source, cube: ToneCubeCache())
        else { return nil }

        // Rotate to Fit (clockwise, like Lightroom).
        if layout.rotated {
            image = image.oriented(.right)
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))

        image = resize(image, to: pixels, fill: s.fit == .fill)
        if s.printAdjustment, s.brightness != 0 || s.contrast != 0 {
            image = adjust(image, brightness: s.brightness, contrast: s.contrast)
        }
        if s.sharpening != .off {
            image = sharpen(image, settings: s)
        }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let wide = DevelopRenderer.context.createCGImage(image.cropped(to: rect), from: rect,
                                                               format: .RGBA16, colorSpace: romm)
        else { return nil }

        guard let path = s.profilePath, let paper = PrintProfiles.colorSpace(path) else {
            return convert(wide, to: DevelopRenderer.sRGB, intent: s.intent.cgIntent, bitsPerComponent: 8)
        }
        return convert(wide, to: paper, intent: s.intent.cgIntent, bitsPerComponent: 8)
    }

    /// Soft proof: the printer-space image back on screen. With `simulatePaper` the paper white
    /// and ink black are shown as they print (absolute colorimetric); otherwise white = white.
    static func proof(_ printImage: CGImage, simulatePaper: Bool) -> CGImage? {
        convert(printImage, to: displayP3,
                intent: simulatePaper ? .absoluteColorimetric : .relativeColorimetric,
                bitsPerComponent: 8)
    }

    /// The paper's white on screen (absolute colorimetric), for the soft-proofed page.
    static func paperWhite(profilePath: String) -> CGColor? {
        guard let paper = PrintProfiles.colorSpace(profilePath), paper.model == .rgb,
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: paper, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(colorSpace: paper, components: [1, 1, 1, 1]) ?? CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let white = context.makeImage(), let shown = proof(white, simulatePaper: true) else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        let read = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let reader = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                         bytesPerRow: 4, space: displayP3,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            reader.draw(shown, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard read else { return nil }
        return CGColor(colorSpace: displayP3,
                       components: [CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255, 1])
    }

    // MARK: - Steps

    /// Scales so the photo exactly fits (or, with `fill`, covers and is centre-cropped to) `size`.
    private static func resize(_ image: CIImage, to size: CGSize, fill: Bool) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let sx = size.width / extent.width, sy = size.height / extent.height
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image.clampedToExtent().cropped(to: extent)
        // Fit: exact width and height (the layout already has the photo's aspect ratio).
        filter.scale = Float(fill ? max(sx, sy) : sy)
        filter.aspectRatio = Float(fill ? 1 : sx / sy)
        var output = filter.outputImage ?? image
        let scaled = output.extent
        output = output.transformed(by: CGAffineTransform(translationX: size.width / 2 - scaled.midX,
                                                          y: size.height / 2 - scaled.midY))
        return output.clampedToExtent().cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Print Adjustment, done on gamma-encoded values so the contrast pivot is mid-grey.
    private static func adjust(_ image: CIImage, brightness: Double, contrast: Double) -> CIImage {
        var output = image.applyingFilter("CILinearToSRGBToneCurve")
        if brightness != 0 {
            let gamma = CIFilter.gammaAdjust()
            gamma.inputImage = output
            gamma.power = Float(pow(0.7, brightness / 50)) // +50 brightens the midtones
            output = gamma.outputImage ?? output
        }
        if contrast != 0 {
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.contrast = Float(1 + contrast / 200)
            controls.saturation = 1
            controls.brightness = 0
            output = controls.outputImage ?? output
        }
        return output.applyingFilter("CISRGBToneCurveToLinear")
    }

    /// Output sharpening for the print size: the radius follows the resolution, matte paper
    /// (ink spreads more) gets a slightly larger radius.
    private static func sharpen(_ image: CIImage, settings s: PrintSettings) -> CIImage {
        let filter = CIFilter.unsharpMask()
        filter.inputImage = image
        filter.radius = Float(Double(s.resolution) / 300 * (s.media == .matte ? 1.3 : 0.9))
        filter.intensity = Float(s.sharpening.intensity)
        return (filter.outputImage ?? image).cropped(to: image.extent)
    }

    /// Colour conversion through ColorSync with the given rendering intent (Core Graphics
    /// converts when drawing into a context of another colour space).
    static func convert(_ image: CGImage, to space: CGColorSpace, intent: CGColorRenderingIntent,
                        bitsPerComponent: Int) -> CGImage? {
        let bytesPerPixel = 4 * bitsPerComponent / 8
        let info: UInt32 = bitsPerComponent == 16
            ? CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        guard bitsPerComponent == 8 || bitsPerComponent == 16, space.model == .rgb,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: bitsPerComponent,
                                      bytesPerRow: image.width * bytesPerPixel,
                                      space: space, bitmapInfo: info)
        else { return nil }
        context.setRenderingIntent(intent)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
