import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Builds mask images and applies local adjustments (Masking panel).
///
/// Runs on the globally developed photo, before crop/straighten. Each mask is a
/// grey image (white = full effect) made from its components, combined top to bottom
/// (Add = max, Subtract = × (1 − c), Intersect = ×). The adjusted photo is blended
/// through it.
enum MaskRenderer {
    struct Kernels {
        let shape: CIKernel
        let range: CIKernel
        let local: CIKernel
    }

    static let kernels: Kernels? = {
        guard let list = try? CIKernel.kernels(withMetalString: source),
              let shape = list.first(where: { $0.name == "dmShape" }),
              let range = list.first(where: { $0.name == "dmRange" }),
              let local = list.first(where: { $0.name == "dmLocal" })
        else { return nil }
        return Kernels(shape: shape, range: range, local: local)
    }()

    /// `overlay`: that mask is also shown as a red tint (even when it changes nothing yet).
    static func apply(_ masks: [MaskLayer], to image: CIImage, url: URL?,
                      overlay: UUID?, presence: CIKernel?) -> CIImage {
        guard let k = kernels else { return image }
        let extent = image.extent
        let base = image
        var output = image
        var overlayMask: CIImage?
        for layer in masks where layer.visible || layer.id == overlay {
            let needed = layer.visible && !layer.adjustments.isNeutral
            guard needed || layer.id == overlay,
                  let mask = maskImage(layer, base: base, url: url, kernels: k) else { continue }
            if layer.id == overlay { overlayMask = mask }
            guard needed else { continue }
            var adjusted = output
            let a = layer.adjustments
            if a.presenceActive, let presence {
                adjusted = DevelopKernel.applyPresence(presence, to: adjusted, effects: a.presence)
            }
            adjusted = local(adjusted, a, kernel: k.local)
            adjusted = sharpen(adjusted, amount: a.sharpness)
            output = adjusted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: output,
                kCIInputMaskImageKey: mask,
            ]).cropped(to: extent)
        }
        if let overlayMask {
            let red = CIImage(color: CIColor(red: 0.95, green: 0.12, blue: 0.18)).cropped(to: extent)
            let half = overlayMask.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.5, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.5, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.5, w: 0),
            ])
            output = red.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: output,
                kCIInputMaskImageKey: half,
            ]).cropped(to: extent)
        }
        return output
    }

    // MARK: - Masks

    static func maskImage(_ layer: MaskLayer, base: CIImage, url: URL?, kernels k: Kernels) -> CIImage? {
        let extent = base.extent
        var mask: CIImage?
        for component in layer.components {
            guard var c = componentImage(component, base: base, url: url, kernels: k) else { continue }
            c = c.cropped(to: extent)
            if component.invert && component.kind != .radial {
                c = c.applyingFilter("CIColorInvert")
            }
            guard let current = mask else {
                mask = component.mode == .subtract ? nil : c
                continue
            }
            switch component.mode {
            case .add:
                mask = c.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: current])
            case .subtract:
                mask = c.applyingFilter("CIColorInvert")
                    .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: current])
            case .intersect:
                mask = c.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: current])
            }
        }
        return mask?.cropped(to: extent)
    }

    private static func componentImage(_ c: MaskComponent, base: CIImage, url: URL?, kernels k: Kernels) -> CIImage? {
        let e = base.extent
        let long = max(e.width, e.height)
        func ci(_ p: MaskPoint) -> CIVector {
            CIVector(x: e.minX + CGFloat(p.x) * e.width, y: e.minY + CGFloat(1 - p.y) * e.height)
        }
        switch c.kind {
        case .linear:
            let s = ci(c.start), t = ci(c.end)
            return DevelopKernel.run(k.shape, extent: e, arguments: [
                CIVector(x: s.x, y: s.y, z: t.x, w: t.y), CIVector(x: 0, y: 0, z: 0, w: 0), NSNumber(value: 0),
            ])
        case .radial:
            let p = ci(c.center)
            return DevelopKernel.run(k.shape, extent: e, arguments: [
                CIVector(x: p.x, y: p.y, z: CGFloat(c.radiusX) * long, w: CGFloat(c.radiusY) * long),
                CIVector(x: CGFloat(-c.angle * .pi / 180), y: CGFloat(min(max(c.feather, 0), 100) / 100),
                         z: c.invert ? 1 : 0, w: 0),
                NSNumber(value: 1),
            ])
        case .brush:
            return BrushRasterizer.image(c.strokes, extent: e)
        case .subject:
            guard let mask = SubjectMaskStore.shared.mask(url: url, base: base) else {
                return CIImage(color: .black).cropped(to: e)
            }
            // Grey masks are data, not colours: no colour management.
            let image = CIImage(cgImage: mask, options: [.colorSpace: NSNull()])
            return image.transformed(by: CGAffineTransform(scaleX: e.width / image.extent.width,
                                                           y: e.height / image.extent.height)
                .concatenating(CGAffineTransform(translationX: e.minX, y: e.minY)))
        case .luminanceRange:
            return DevelopKernel.run(k.range, extent: e, arguments: [
                base,
                CIVector(x: CGFloat(min(c.lumLow, c.lumHigh)), y: CGFloat(max(c.lumLow, c.lumHigh)),
                         z: CGFloat(c.lumSmoothness), w: 0),
                NSNumber(value: 0),
            ])
        case .colorRange:
            guard c.hasPickedColor else { return CIImage(color: .black).cropped(to: e) }
            return DevelopKernel.run(k.range, extent: e, arguments: [
                base,
                CIVector(x: CGFloat(c.pickL), y: CGFloat(c.pickA), z: CGFloat(c.pickB),
                         w: CGFloat(min(max(c.colorAmount, 0), 100) / 100)),
                NSNumber(value: 1),
            ])
        }
    }

    // MARK: - Adjustments

    private static func local(_ image: CIImage, _ a: LocalAdjustments, kernel: CIKernel) -> CIImage {
        let tone = a.exposure != 0 || a.contrast != 0 || a.highlights != 0 || a.shadows != 0
            || a.whites != 0 || a.blacks != 0
        let color = a.temperature != 0 || a.tint != 0 || a.saturation != 0 || a.colorSaturation != 0
        guard tone || color else { return image }
        let tintDirection = LumaEngine.hueDirection(a.colorHue) * (min(max(a.colorSaturation, 0), 100) / 100 * 0.08)
        let arguments: [Any] = [
            image,
            CIVector(x: CGFloat(a.exposure), y: CGFloat(a.contrast / 100),
                     z: CGFloat(a.highlights / 100), w: CGFloat(a.shadows / 100)),
            CIVector(x: CGFloat(a.whites / 100), y: CGFloat(a.blacks / 100),
                     z: CGFloat(a.saturation / 100), w: CGFloat(a.temperature / 100)),
            CIVector(x: CGFloat(a.tint / 100), y: CGFloat(tintDirection.x), z: CGFloat(tintDirection.y), w: 0),
        ]
        return DevelopKernel.run(kernel, extent: image.extent, arguments: arguments)?.cropped(to: image.extent) ?? image
    }

    private static func sharpen(_ image: CIImage, amount: Double) -> CIImage {
        guard amount != 0 else { return image }
        let e = image.extent
        let long = max(e.width, e.height)
        if amount > 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = image
            filter.sharpness = Float(amount / 100 * 1.2)
            filter.radius = Float(max(0.6, 1.2 * long / 3000))
            return filter.outputImage?.cropped(to: e) ?? image
        }
        return image.clampedToExtent()
            .applyingGaussianBlur(sigma: -amount / 100 * 3 * Double(long) / 3000 + 0.3)
            .cropped(to: e)
    }

    // MARK: - Metal source

    static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    inline float dmSig(float x) { return 1.0 / (1.0 + exp(-x)); }
    inline float dmEnc1(float v) { v = max(v, 0.0); return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055; }
    inline float dmDec1(float v) { v = max(v, 0.0); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4); }
    inline float3 dmEnc(float3 c) { return float3(dmEnc1(c.r), dmEnc1(c.g), dmEnc1(c.b)); }
    inline float3 dmDec(float3 c) { return float3(dmDec1(c.r), dmDec1(c.g), dmDec1(c.b)); }
    inline float dmLuma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
    inline float dmSmooth(float a, float b, float x) { float t = clamp((x - a) / (b - a), 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }

    inline float3 dmOklab(float3 c) {
      float3 lms = float3(
        dot(c, float3(0.4122214708, 0.5363325363, 0.0514459929)),
        dot(c, float3(0.2119034982, 0.6806995451, 0.1073969566)),
        dot(c, float3(0.0883024619, 0.2817188376, 0.6299787005)));
      lms = pow(max(lms, 0.0), float3(1.0 / 3.0));
      return float3(
        dot(lms, float3(0.2104542553, 0.7936177850, -0.0040720468)),
        dot(lms, float3(1.9779984951, -2.4285922050, 0.4505937099)),
        dot(lms, float3(0.0259040371, 0.7827717662, -0.8086757660)));
    }

    inline float3 dmFromOklab(float3 o) {
      float3 lms = float3(
        o.x + 0.3963377774 * o.y + 0.2158037573 * o.z,
        o.x - 0.1055613458 * o.y - 0.0638541728 * o.z,
        o.x - 0.0894841775 * o.y - 1.2914855480 * o.z);
      lms = lms * lms * lms;
      return float3(
        dot(lms, float3(4.0767416621, -3.3077115913, 0.2309699292)),
        dot(lms, float3(-1.2684380046, 2.6097574011, -0.3413193965)),
        dot(lms, float3(-0.0041960863, -0.7034186147, 1.7076147010)));
    }

    inline float3 dmFitGamut(float3 c) {
      c = max(c, 0.0);
      float m = max(c.r, max(c.g, c.b));
      if (m <= 1.0) return c;
      float y = dmLuma(c);
      if (y >= 1.0) return float3(1.0);
      float t = (1.0 - y) / (m - y);
      return max(y + (c - y) * t, 0.0);
    }

    inline float3 dmScaleChroma(float3 c, float k) {
      float l = dmLuma(c);
      k = max(0.0, k);
      float3 r = l + (c - l) * k;
      return clamp(r, 0.0, 1.0);
    }

    // Logistic S-curve around 0.5 (k = 6), anchored at 0 and 1.
    inline float dmContrast(float p, float c) {
      if (c == 0.0) return p;
      float s0 = dmSig(-3.0), s1 = dmSig(3.0);
      float a = abs(c);
      float q = clamp(p, 0.0, 1.0);
      float target;
      if (c > 0.0) {
        target = (dmSig(6.0 * (q - 0.5)) - s0) / (s1 - s0);
      } else {
        float t = clamp(q * (s1 - s0) + s0, 1e-6, 1.0 - 1e-6);
        target = 0.5 + log(t / (1.0 - t)) / 6.0;
      }
      return p + a * (target - p);
    }

    // Linear (mode 0) or radial (mode 1) gradient mask, white = full effect.
    // Linear: p = (start, end). Radial: p = (centre, radii), q = (angle, feather, invert).
    [[ stitchable ]] float4 dmShape(float4 p, float4 q, float mode, coreimage::destination dest) {
      float2 pos = dest.coord();
      float m;
      if (mode < 0.5) {
        float2 d = p.zw - p.xy;
        float t = dot(pos - p.xy, d) / max(dot(d, d), 1e-6);
        m = 1.0 - dmSmooth(0.0, 1.0, t);
      } else {
        float2 d = pos - p.xy;
        float ca = cos(q.x), sa = sin(q.x);
        float2 r = float2(d.x * ca + d.y * sa, -d.x * sa + d.y * ca) / max(p.zw, float2(1e-3));
        float f = clamp(q.y, 0.01, 1.0);
        m = 1.0 - dmSmooth(1.0 - f, 1.0, length(r));
        if (q.z > 0.5) m = 1.0 - m;
      }
      return float4(m, m, m, 1.0);
    }

    // Luminance range (mode 0): p = (low, high, smoothness). Colour range (mode 1):
    // p = (Oklab L, a, b, amount).
    [[ stitchable ]] float4 dmRange(coreimage::sample_t s, float4 p, float mode) {
      float3 lin = clamp(s.rgb, 0.0, 1.0);
      float m;
      if (mode < 0.5) {
        float l = dmEnc1(dmLuma(lin));
        float sm = max(p.z, 0.002);
        m = dmSmooth(p.x - sm, p.x, l) * (1.0 - dmSmooth(p.y, p.y + sm, l));
      } else {
        float3 o = dmOklab(lin);
        float3 d = o - p.xyz;
        float dist = length(float3(d.x * 0.5, d.y, d.z));
        float r = 0.02 + 0.13 * p.w;
        m = 1.0 - dmSmooth(r * 0.4, r, dist);
      }
      return float4(m, m, m, 1.0);
    }

    // Local adjustments on the developed photo (linear).
    // a = (exposure EV, contrast, highlights, shadows), b = (whites, blacks, saturation, temp),
    // c = (tint, colour tint Oklab a, b, 0); sliders as −1…1.
    [[ stitchable ]] float4 dmLocal(coreimage::sample_t s, float4 a, float4 b, float4 c) {
      float3 lin = max(s.rgb, 0.0);
      if (b.w != 0.0 || c.x != 0.0) {
        float y0 = dmLuma(lin);
        lin *= float3(exp2(0.45 * b.w), exp2(-0.35 * c.x), exp2(-0.45 * b.w));
        float y1 = dmLuma(lin);
        if (y1 > 1e-6) lin *= y0 / y1;
      }
      lin *= exp2(a.x);
      bool tone = a.y != 0.0 || a.z != 0.0 || a.w != 0.0 || b.x != 0.0 || b.y != 0.0;
      if (tone) {
        float y = dmLuma(lin);
        if (y > 1e-8) {
          float e = dmEnc1(y);
          float e2 = e;
          e2 += a.z * 0.25 * dmSmooth(0.4, 1.0, e);
          e2 += a.w * 0.25 * (1.0 - dmSmooth(0.05, 0.6, e)) * dmSmooth(0.0, 0.1, e);
          e2 += b.x * 0.15 * dmSmooth(0.6, 1.0, e);
          e2 += b.y * 0.15 * (1.0 - dmSmooth(0.0, 0.4, e));
          e2 = dmContrast(e2, a.y);
          lin *= dmDec1(clamp(e2, 0.0, 1.2)) / y;
        }
      }
      float3 col = dmEnc(dmFitGamut(lin));
      if (b.z != 0.0) col = dmScaleChroma(col, 1.0 + b.z);
      if (c.y != 0.0 || c.z != 0.0) {
        float3 o = dmOklab(dmDec(col));
        float fade = dmSmooth(0.02, 0.2, o.x);
        o.yz += c.yz * fade;
        col = dmEnc(dmFitGamut(dmFromOklab(o)));
      }
      return float4(dmDec(clamp(col, 0.0, 1.0)), s.a);
    }
    """
}

// MARK: - Brush

/// Paints brush strokes into a grey bitmap (cached, the strokes rarely change between renders).
enum BrushRasterizer {
    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 24
        return cache
    }()

    static let maxSide: CGFloat = 1536

    static func image(_ strokes: [BrushStroke], extent e: CGRect) -> CIImage? {
        guard e.width > 0, e.height > 0 else { return nil }
        let scale = maxSide / max(e.width, e.height)
        let w = max(1, Int((e.width * scale).rounded())), h = max(1, Int((e.height * scale).rounded()))
        let key = "\(strokes.hashValue)-\(strokes.count)-\(w)x\(h)" as NSString
        let cg: CGImage
        if let box = cache.object(forKey: key) {
            cg = box.image
        } else {
            guard let drawn = draw(strokes, width: w, height: h) else { return nil }
            cache.setObject(Box(drawn), forKey: key)
            cg = drawn
        }
        return CIImage(cgImage: cg, options: [.colorSpace: NSNull()]).transformed(by: CGAffineTransform(scaleX: e.width / CGFloat(w), y: e.height / CGFloat(h))
            .concatenating(CGAffineTransform(translationX: e.minX, y: e.minY)))
    }

    private static func draw(_ strokes: [BrushStroke], width w: Int, height h: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let long = CGFloat(max(w, h))
        for stroke in strokes where !stroke.points.isEmpty {
            let radius = max(1, CGFloat(stroke.radius) * long)
            let value: CGFloat = stroke.erase ? 0 : 1
            let flow = CGFloat(min(max(stroke.flow, 0.02), 1))
            let inner = CGFloat(1 - min(max(stroke.feather, 0), 0.98))
            guard let gradient = CGGradient(
                colorSpace: CGColorSpaceCreateDeviceGray(),
                colorComponents: [value, flow, value, flow, value, 0],
                locations: [0, inner, 1], count: 3) else { continue }
            func dab(_ p: CGPoint) {
                context.drawRadialGradient(gradient, startCenter: p, startRadius: 0,
                                           endCenter: p, endRadius: radius, options: [])
            }
            let points = stroke.points.map { CGPoint(x: CGFloat($0.x) * CGFloat(w), y: CGFloat(1 - $0.y) * CGFloat(h)) }
            dab(points[0])
            let spacing = max(1, radius * 0.2)
            var carry: CGFloat = 0
            for i in points.indices.dropFirst() {
                let a = points[i - 1], b = points[i]
                let length = hypot(b.x - a.x, b.y - a.y)
                guard length > 0 else { continue }
                var t = spacing - carry
                while t <= length {
                    dab(CGPoint(x: a.x + (b.x - a.x) * t / length, y: a.y + (b.y - a.y) * t / length))
                    t += spacing
                }
                carry = length - (t - spacing)
            }
        }
        return context.makeImage()
    }
}

// MARK: - Select Subject (macOS Vision)

/// Subject masks from Vision's foreground segmentation, one per photo file: kept in
/// memory and in ~/Library/Application Support/Darkroom/Masks so they are made once.
final class SubjectMaskStore {
    static let shared = SubjectMaskStore()

    private final class Box {
        let image: CGImage?
        init(_ image: CGImage?) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()
    private let lock = NSLock()
    private let context = CIContext()
    static let workSide: CGFloat = 1024

    private lazy var folder: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let url = base.appendingPathComponent("Darkroom/Masks", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Grey mask (white = subject), or nil when Vision finds no subject.
    func mask(url: URL?, base: CIImage) -> CGImage? {
        // Masks made from small images (thumbnails) are kept apart and never saved.
        let small = max(base.extent.width, base.extent.height) < Self.workSide * 0.9
        let path = url?.path ?? "unsaved"
        let key = (small ? path + "#small" : path) as NSString
        lock.lock()
        defer { lock.unlock() }
        if let box = cache.object(forKey: path as NSString) { return box.image }
        if let box = cache.object(forKey: key) { return box.image }
        let file = url.flatMap { fileURL(for: $0) }
        if let file, let source = CGImageSourceCreateWithURL(file as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            cache.setObject(Box(image), forKey: path as NSString)
            return image
        }
        let made = compute(base)
        cache.setObject(Box(made), forKey: key)
        if let made, let file, !small {
            save(made, to: file)
        }
        return made
    }

    func forget(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeObject(forKey: url.path as NSString)
        cache.removeObject(forKey: (url.path + "#small") as NSString)
        if let file = fileURL(for: url) { try? FileManager.default.removeItem(at: file) }
    }

    private func fileURL(for url: URL) -> URL? {
        // FNV-1a hash of the path.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return folder?.appendingPathComponent(String(format: "%016llx.png", hash))
    }

    private func compute(_ base: CIImage) -> CGImage? {
        let e = base.extent
        guard e.width > 0, e.height > 0 else { return nil }
        let scale = min(1, Self.workSide / max(e.width, e.height))
        let small = base.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale)))
        guard let input = context.createCGImage(small, from: small.extent.integral, format: .RGBA8,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: input, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return nil }
            let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
            let mask = CIImage(cvPixelBuffer: buffer)
            return context.createCGImage(mask, from: mask.extent, format: .L8,
                                         colorSpace: CGColorSpaceCreateDeviceGray())
        } catch {
            return nil
        }
    }

    private func save(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
