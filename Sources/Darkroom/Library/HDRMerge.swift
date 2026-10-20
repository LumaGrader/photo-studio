import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Vision
import simd

/// HDR Merge options (the HDR Merge sheet).
struct HDRMergeOptions: Equatable {
    enum Deghost: String, CaseIterable, Identifiable {
        case none = "None"
        case low = "Low"
        case medium = "Medium"
        case high = "High"
        var id: String { rawValue }

        /// How far (in stops) a frame may differ from the reference before it's left out.
        var tolerance: Float {
            switch self {
            case .none: return 0
            case .low: return 1.0
            case .medium: return 0.6
            case .high: return 0.35
            }
        }
    }

    /// Line the frames up (handheld brackets).
    var autoAlign = true
    /// Auto Tone on the merged photo.
    var autoSettings = true
    var deghost: Deghost = .none
}

/// Merges bracketed exposures into one high-dynamic-range photo, saved as a 16-bit float
/// TIFF (linear light, values above 1 kept) next to the originals, so Exposure, Highlights
/// and Whites can bring back what a single frame clipped.
///
/// 1. Each frame is decoded the same way Develop decodes it (RAW: macOS decoder defaults).
/// 2. The middle exposure is the reference; the others are aligned to it (Vision homography,
///    checked against identity so a bad match can't make things worse).
/// 3. Exposure ratios are measured from the pixels (EXIF as a fallback).
/// 4. Per pixel, every frame is brought to the reference's exposure and averaged with a
///    weight that favours well-exposed, unclipped values; Deghost drops frames that
///    disagree with the reference where something moved.
enum HDRMerge {
    enum MergeError: LocalizedError {
        case tooFew, unreadable(String), differentSizes, kernels, write(String)

        var errorDescription: String? {
            switch self {
            case .tooFew: return "Select 2 to 9 photos of the same scene at different exposures."
            case .unreadable(let name): return "Couldn't read \(name)."
            case .differentSizes: return "The photos have different sizes or orientations, so they can't be merged."
            case .kernels: return "The HDR merge filters couldn't be prepared."
            case .write(let reason): return "Couldn't save the merged photo: \(reason)"
            }
        }
    }

    private struct Frame {
        let url: URL
        let image: CIImage        // full size, origin (0, 0)
        let proxy: CIImage        // ≤ 1024 px, origin (0, 0)
        let small: LumaMap        // ≤ 256 px luminance, for measuring
        let exposure: Double?     // EXIF exposure amount (time × ISO / f²)
    }

    /// Returns the URL of the merged TIFF.
    static func merge(urls: [URL], options: HDRMergeOptions,
                      progress: @escaping (String) -> Void) throws -> URL {
        guard (2...9).contains(urls.count) else { throw MergeError.tooFew }
        guard let kernels = Kernels.shared else { throw MergeError.kernels }
        let context = DevelopRenderer.context

        progress("Reading \(urls.count) photos…")
        var frames: [Frame] = []
        for url in urls {
            guard let image = load(url) else { throw MergeError.unreadable(url.lastPathComponent) }
            let long = max(image.extent.width, image.extent.height)
            let proxy = scaled(image, to: min(1, 1024 / long))
            let small = LumaMap(scaled(image, to: min(1, 256 / long)), context: context)
            frames.append(Frame(url: url, image: image, proxy: proxy, small: small, exposure: exposureAmount(url)))
        }
        let size = frames[0].image.extent.size
        guard frames.allSatisfy({ abs($0.image.extent.width - size.width) < 1 && abs($0.image.extent.height - size.height) < 1 })
        else { throw MergeError.differentSizes }

        // Reference = the middle exposure.
        let brightness: [Double] = frames.map { $0.exposure ?? Double($0.small.mean) }
        let order = brightness.indices.sorted { brightness[$0] < brightness[$1] }
        let refIndex = order[order.count / 2]
        let ref = frames[refIndex]

        // Alignment (moving → reference, in proxy pixels) and exposure ratio per frame.
        var transforms = [simd_float3x3](repeating: matrix_identity_float3x3, count: frames.count)
        var ratios = [Float](repeating: 1, count: frames.count)
        for i in frames.indices where i != refIndex {
            progress(options.autoAlign ? "Aligning photo \(i + 1) of \(frames.count)…" : "Measuring exposures…")
            let exifRatio: Float? = {
                guard let a = frames[i].exposure, let b = ref.exposure, a > 0, b > 0 else { return nil }
                return Float(a / b)
            }()
            var candidates = [matrix_identity_float3x3]
            if options.autoAlign,
               let h = homography(moving: frames[i].proxy, reference: ref.proxy, ratio: exifRatio ?? 1) {
                let height = Float(ref.proxy.extent.height)
                let flip = simd_float3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, -1, height), SIMD3(0, 0, 1)])
                let inverse = h.inverse
                candidates += [h, inverse, flip * h * flip, flip * inverse * flip]
            }
            var best: (error: Float, ratio: Float, transform: simd_float3x3)?
            for t in candidates {
                guard let m = match(moving: frames[i].small, reference: ref.small, transform: t,
                                    proxySize: ref.proxy.extent.size) else { continue }
                // Identity wins ties (a homography must clearly help).
                let penalty: Float = t == matrix_identity_float3x3 ? 0 : 0.002
                if best == nil || m.error + penalty < best!.error {
                    best = (m.error + penalty, m.ratio, t)
                }
            }
            transforms[i] = best?.transform ?? matrix_identity_float3x3
            ratios[i] = best?.ratio ?? exifRatio ?? 1
        }

        // Darkest / brightest frames fill in where every other frame is clipped or black.
        let darkest = ratios.indices.min { ratios[$0] < ratios[$1] } ?? refIndex
        let brightest = ratios.indices.max { ratios[$0] < ratios[$1] } ?? refIndex

        progress("Merging…")
        let extent = ref.image.extent
        let proxyScale = Float(ref.image.extent.width / ref.proxy.extent.width)
        var acc = CIImage(color: .clear).cropped(to: extent)
        for i in frames.indices {
            let aligned = i == refIndex ? frames[i].image
                : warp(frames[i].image, transform: transforms[i], scale: proxyScale).cropped(to: extent)
            let params = CIVector(x: CGFloat(1 / max(ratios[i], 1e-6)), y: 1,
                                  z: i == darkest ? 1 : 0, w: i == brightest ? 1 : 0)
            let deghost = CIVector(x: CGFloat(options.deghost.tolerance), y: i == refIndex ? 1 : 0, z: 0, w: 0)
            guard let next = kernels.add.apply(extent: extent, arguments: [acc, aligned, ref.image, params, deghost])
            else { throw MergeError.kernels }
            acc = next
        }
        guard let merged = kernels.normalize.apply(extent: extent, arguments: [acc])?.cropped(to: extent)
        else { throw MergeError.kernels }

        progress("Saving…")
        let output = uniqueURL(for: ref.url)
        try write(merged, metadataFrom: ref.url, to: output, context: context)
        return output
    }

    // MARK: - Decoding

    /// Same decode as Develop: RAW through the macOS decoder (default rendering), other
    /// files with their orientation applied. Linear light, origin (0, 0).
    static func load(_ url: URL) -> CIImage? {
        var image: CIImage?
        if FolderScanner.rawExtensions.contains(url.pathExtension.lowercased()), let filter = CIRAWFilter(imageURL: url) {
            image = filter.outputImage
        } else {
            image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        }
        guard let image, !image.extent.isEmpty, !image.extent.isInfinite else { return nil }
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    private static func scaled(_ image: CIImage, to scale: CGFloat) -> CIImage {
        guard scale < 1 else { return image }
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image
        filter.scale = Float(scale)
        filter.aspectRatio = 1
        guard let output = filter.outputImage else { return image }
        return output.transformed(by: CGAffineTransform(translationX: -output.extent.minX, y: -output.extent.minY))
            .cropped(to: CGRect(origin: .zero, size: CGSize(width: floor(output.extent.width),
                                                            height: floor(output.extent.height))))
    }

    /// Exposure time × ISO / f-number², from EXIF (nil when missing).
    static func exposureAmount(_ url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let time = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue, time > 0
        else { return nil }
        let fNumber = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue ?? 0
        let iso = ((exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first)?.doubleValue ?? 100
        let aperture = fNumber > 0 ? fNumber * fNumber : 1
        return time * max(iso, 1) / aperture
    }

    // MARK: - Alignment

    /// Vision's homography between two proxies (the moving one brightened or darkened to
    /// the reference first, so both look alike). Its coordinate conventions are checked by
    /// `match`, which tries the matrix, its inverse and the y-flipped versions.
    private static func homography(moving: CIImage, reference: CIImage, ratio: Float) -> simd_float3x3? {
        let ev = -log2(Double(max(ratio, 1e-6)))
        let normalized = moving.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
        let request = VNHomographicImageRegistrationRequest(targetedCIImage: normalized, options: [:])
        let handler = VNImageRequestHandler(ciImage: reference, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNImageHomographicAlignmentObservation else { return nil }
        let h = observation.warpTransform
        guard h.determinant.isFinite, abs(h.determinant) > 1e-6 else { return nil }
        return h
    }

    /// How well `moving`, mapped onto the reference by `transform` (proxy pixels, Core Image
    /// coordinates), matches it: the exposure ratio and a robust log error.
    private static func match(moving: LumaMap, reference: LumaMap, transform: simd_float3x3,
                              proxySize: CGSize) -> (error: Float, ratio: Float)? {
        let inverse = transform.inverse
        let sx = Float(reference.width) / Float(proxySize.width)
        let sy = Float(reference.height) / Float(proxySize.height)
        var pairs: [(r: Float, m: Float)] = []
        pairs.reserveCapacity(reference.width * reference.height / 4)
        for row in stride(from: 1, to: reference.height - 1, by: 2) {
            for col in stride(from: 1, to: reference.width - 1, by: 2) {
                let r = reference.value(col, row)
                guard r > 0.02, r < 0.7 else { continue }
                // Reference pixel → proxy (y up) → moving proxy → moving map.
                let px = (Float(col) + 0.5) / sx
                let py = (Float(reference.height - row) - 0.5) / sy
                let v = inverse * SIMD3<Float>(px, py, 1)
                guard abs(v.z) > 1e-6 else { continue }
                let mx = v.x / v.z * sx - 0.5
                let my = Float(moving.height) - v.y / v.z * sy - 0.5
                guard let m = moving.sample(mx, my), m > 0.02, m < 0.7 else { continue }
                pairs.append((r, m))
            }
        }
        guard pairs.count >= 200 else { return nil }
        let ratio = median(pairs.map { $0.m / $0.r })
        guard ratio.isFinite, ratio > 0 else { return nil }
        let error = median(pairs.map { abs(log($0.m / ($0.r * ratio))) })
        return (error, ratio)
    }

    /// Applies a proxy-pixel homography to the full-size image.
    private static func warp(_ image: CIImage, transform: simd_float3x3, scale k: Float) -> CIImage {
        guard transform != matrix_identity_float3x3 else { return image }
        let s = simd_float3x3(diagonal: SIMD3(k, k, 1))
        let t = s * transform * s.inverse
        let e = image.extent
        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let v = t * SIMD3<Float>(Float(x), Float(y), 1)
            return CGPoint(x: CGFloat(v.x / v.z), y: CGFloat(v.y / v.z))
        }
        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = image
        filter.topLeft = map(e.minX, e.maxY)
        filter.topRight = map(e.maxX, e.maxY)
        filter.bottomRight = map(e.maxX, e.minY)
        filter.bottomLeft = map(e.minX, e.minY)
        return filter.outputImage ?? image
    }

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: - Output

    /// "<reference name>-HDR.tif" next to the reference, never overwriting.
    private static func uniqueURL(for reference: URL) -> URL {
        let folder = reference.deletingLastPathComponent()
        let base = reference.deletingPathExtension().lastPathComponent + "-HDR"
        var url = folder.appendingPathComponent(base + ".tif")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base)-\(n).tif")
            n += 1
        }
        return url
    }

    /// 16-bit float TIFF in extended linear sRGB, with the reference's camera metadata
    /// (orientation reset: the pixels are already upright).
    private static func write(_ image: CIImage, metadataFrom reference: URL, to url: URL, context: CIContext) throws {
        guard let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { throw MergeError.write("no colour space") }
        var tagged = image
        if let source = CGImageSourceCreateWithURL(reference as CFURL, nil),
           var props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            props[kCGImagePropertyOrientation as String] = 1
            if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                tiff[kCGImagePropertyTIFFOrientation as String] = 1
                props[kCGImagePropertyTIFFDictionary as String] = tiff
            }
            for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                        kCGImagePropertyColorModel, kCGImagePropertyProfileName] {
                props.removeValue(forKey: key as String)
            }
            tagged = image.settingProperties(props)
        }
        do {
            try context.writeTIFFRepresentation(of: tagged, to: url, format: .RGBAh, colorSpace: linear, options: [:])
        } catch {
            do {
                try context.writeTIFFRepresentation(of: tagged, to: url, format: .RGBAf, colorSpace: linear, options: [:])
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw MergeError.write(error.localizedDescription)
            }
        }
    }

    // MARK: - Kernels

    private struct Kernels {
        let add: CIColorKernel
        let normalize: CIColorKernel

        static let shared: Kernels? = {
            guard let list = try? CIKernel.kernels(withMetalString: source),
                  let add = list.first(where: { $0.name == "hdrAdd" }) as? CIColorKernel,
                  let normalize = list.first(where: { $0.name == "hdrNormalize" }) as? CIColorKernel
            else { return nil }
            return Kernels(add: add, normalize: normalize)
        }()
    }

    private static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    inline float hdrSmooth(float a, float b, float x) {
      float t = clamp((x - a) / max(b - a, 1e-5), 0.0, 1.0);
      return t * t * (3.0 - 2.0 * t);
    }

    inline float hdrMax(float3 c) { return max(max(c.r, c.g), c.b); }

    // Adds one frame: acc.rgb += radiance · w, acc.a += w.
    // p: x = scale to the reference's exposure, y = (unused, 1), z = 1 darkest frame,
    //    w = 1 brightest frame. q: x = deghost tolerance in stops (0 = off), y = 1 reference.
    [[ stitchable ]] float4 hdrAdd(coreimage::sample_t acc, coreimage::sample_t img, coreimage::sample_t ref,
                                   float4 p, float4 q) {
      float a = img.a;
      if (a < 1e-4) { return acc; }
      float3 c = max(img.rgb / a, 0.0);
      float e = pow(clamp(hdrMax(c), 0.0, 1.0), 1.0 / 2.2);
      // Well exposed: not in the noise, not near clipping.
      float w = hdrSmooth(0.02, 0.15, e) * (1.0 - hdrSmooth(0.85, 0.97, e));
      // Fallbacks so no pixel is left without a frame.
      w += p.z * 1e-3 * hdrSmooth(0.1, 0.5, e);
      w += p.w * 1e-3 * (1.0 - hdrSmooth(0.5, 0.9, e));
      float3 radiance = c * p.x;
      if (q.x > 0.0 && q.y < 0.5) {
        float3 cr = max(ref.rgb / max(ref.a, 1e-4), 0.0);
        float er = pow(clamp(hdrMax(cr), 0.0, 1.0), 1.0 / 2.2);
        float reliable = hdrSmooth(0.05, 0.2, er) * (1.0 - hdrSmooth(0.8, 0.95, er));
        float3 lw = float3(0.2126, 0.7152, 0.0722);
        float d = abs(log2((dot(radiance, lw) + 1e-4) / (dot(cr, lw) + 1e-4)));
        w *= mix(1.0, exp(-(d * d) / (q.x * q.x)), reliable);
      }
      w *= a;
      return acc + float4(radiance * w, w);
    }

    [[ stitchable ]] float4 hdrNormalize(coreimage::sample_t acc) {
      return float4(acc.rgb / max(acc.a, 1e-8), 1.0);
    }
    """
}

/// Small luminance bitmap (linear), rows top first.
private struct LumaMap {
    let width: Int
    let height: Int
    let values: [Float]

    init(_ image: CIImage, context: CIContext) {
        let w = max(Int(image.extent.width), 1), h = max(Int(image.extent.height), 1)
        var rgba = [Float](repeating: 0, count: w * h * 4)
        context.render(image, toBitmap: &rgba, rowBytes: w * 16,
                       bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: nil)
        var luma = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            luma[i] = 0.2126 * rgba[i * 4] + 0.7152 * rgba[i * 4 + 1] + 0.0722 * rgba[i * 4 + 2]
        }
        width = w
        height = h
        values = luma
    }

    var mean: Float { values.isEmpty ? 0 : values.reduce(0, +) / Float(values.count) }

    func value(_ x: Int, _ y: Int) -> Float { values[y * width + x] }

    /// Bilinear sample at map coordinates (pixel centres at integers), nil outside.
    func sample(_ x: Float, _ y: Float) -> Float? {
        guard x >= 0, y >= 0, x < Float(width - 1), y < Float(height - 1) else { return nil }
        let x0 = Int(x), y0 = Int(y)
        let fx = x - Float(x0), fy = y - Float(y0)
        let a = value(x0, y0), b = value(x0 + 1, y0)
        let c = value(x0, y0 + 1), d = value(x0 + 1, y0 + 1)
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }
}
