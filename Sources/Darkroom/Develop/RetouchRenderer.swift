import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

/// Spot Removal (Heal / Clone), Darkroom Denoise and Lens Blur.
/// All three run on the uncropped photo, like masks, so they stay put when the crop changes.
enum RetouchRenderer {
    struct Kernels {
        let ring: CIKernel
        let spot: CIKernel
        let toOklab: CIKernel
        let fromOklab: CIKernel
        let denoise: CIKernel
        let maskWeight: CIKernel
        let normalize: CIKernel
        let fill: CIKernel
        let boost: CIKernel
        let mix: CIKernel
        let lensMix: CIKernel
        let focus: CIKernel
        let ground: CIKernel
    }

    static let compiled: Result<Kernels, Error> = {
        do {
            let list = try CIKernel.kernels(withMetalString: source)
            func k(_ name: String) -> CIKernel? { list.first { $0.name == name } }
            guard let ring = k("rtRing"), let spot = k("rtSpot"),
                  let toOklab = k("rtToOklab"), let fromOklab = k("rtFromOklabK"), let denoise = k("rtDenoise"),
                  let maskWeight = k("rtMaskWeight"), let normalize = k("rtNormalize"), let fill = k("rtFill"), let boost = k("rtBoost"),
                  let mix = k("rtMix"), let lensMix = k("rtLensMix"), let focus = k("rtFocus"),
                  let ground = k("rtGround")
            else { return .failure(DevelopKernel.KernelError.missing) }
            return .success(Kernels(ring: ring, spot: spot, toOklab: toOklab, fromOklab: fromOklab,
                                    denoise: denoise, maskWeight: maskWeight, normalize: normalize, fill: fill,
                                    boost: boost, mix: mix, lensMix: lensMix, focus: focus, ground: ground))
        } catch {
            return .failure(error)
        }
    }()

    static var kernels: Kernels? { try? compiled.get() }

    /// Why Healing / Denoise / Lens Blur can't run (nil = fine).
    static var errorMessage: String? {
        if case let .failure(error) = compiled { return error.localizedDescription }
        return nil
    }

    // MARK: - Spot Removal
    //
    // Every kernel that needs pixel positions is a general kernel with samplers and an
    // explicit region of interest. Core Image may move transforms (crop, zoom) across colour
    // kernels, so a colour kernel that reads `dest.coord()` can end up at the wrong place;
    // and nothing here uses an infinite (clamped) image, whose edge pixels smear outwards.

    static func applySpots(_ spots: [SpotEdit], to image: CIImage) -> CIImage {
        guard !spots.isEmpty, let k = kernels else { return image }
        let e = image.extent
        guard !e.isEmpty, !e.isInfinite else { return image }
        let long = max(e.width, e.height)
        func ci(_ p: MaskPoint) -> CGPoint {
            CGPoint(x: e.minX + CGFloat(p.x) * e.width, y: e.minY + CGFloat(1 - p.y) * e.height)
        }
        let bounds = CIVector(x: e.minX, y: e.minY, z: e.maxX, w: e.maxY)
        // Spots work on a rendered copy of the photo: what comes before (RAW decode, develop
        // kernel, local tone map) is then fixed pixels, so a spot can't make Core Image
        // re-render those stages for just the spot's small area.
        var output = Materialized.image(image) ?? image
        for spot in spots {
            guard spot.radius.isFinite, spot.center.x.isFinite, spot.center.y.isFinite,
                  spot.source.x.isFinite, spot.source.y.isFinite else { continue }
            let d = ci(spot.center), s = ci(spot.source)
            let r = min(max(CGFloat(spot.radius) * long, 1), 0.2 * long)
            let inner = r * CGFloat(1 - min(max(spot.feather, 0), 100) / 100 * 0.9)
            let circle = CGRect(x: d.x - r, y: d.y - r, width: 2 * r, height: 2 * r).intersection(e)
            guard !circle.isEmpty else { continue }
            let shift = CGPoint(x: s.x - d.x, y: s.y - d.y)
            let heal = spot.mode == .heal

            // Heal: light and colour of a ring just outside the spot, at the spot and at the
            // source, as normalised blurs (rgb = Σ colour·w, alpha = Σ w).
            var destLow = output, sourceLow = output
            if heal {
                let sigma = r * 0.6
                let pad = r + 3 * sigma
                func ringBlur(around c: CGPoint) -> CIImage? {
                    let region = CGRect(x: c.x - pad, y: c.y - pad, width: 2 * pad, height: 2 * pad)
                        .integral.intersection(e)
                    guard !region.isEmpty,
                          let weighted = DevelopKernel.run(k.ring, extent: region, arguments: [
                              output, CIVector(x: c.x, y: c.y, z: r, w: inner),
                          ]) else { return nil }
                    return weighted.cropped(to: region).applyingGaussianBlur(sigma: Double(sigma))
                }
                guard let dl = ringBlur(around: d), let sl = ringBlur(around: s) else { continue }
                destLow = dl
                sourceLow = sl
            }

            // One pass over the whole photo (pixels outside the spot pass straight through),
            // so no small patch is composited over the photo.
            let options = CIVector(x: CGFloat(min(max(spot.opacity, 0), 100) / 100), y: heal ? 1 : 0,
                                   z: shift.x, w: shift.y)
            guard let next = DevelopKernel.run(k.spot, extent: e, arguments: [
                output, output, destLow, sourceLow,
                CIVector(x: d.x, y: d.y, z: r, w: inner), options, bounds,
            ], roi: { index, rect in
                switch index {
                case 0: return rect
                // Source pixels: only what the spot reads, moved to the source.
                case 1, 3:
                    let used = rect.intersection(circle)
                    guard !used.isNull, !used.isEmpty else { return .null }
                    return RetouchRenderer.sourceRect(used.offsetBy(dx: shift.x, dy: shift.y), inside: e)
                default:
                    let used = rect.intersection(circle)
                    return used.isNull ? .null : used.insetBy(dx: -2, dy: -2)
                }
            }) else { continue }
            output = next.cropped(to: e)
        }
        return output
    }

    /// `rect` with its corners pulled inside `bounds` (where clamped source reads land).
    private static func sourceRect(_ rect: CGRect, inside bounds: CGRect) -> CGRect {
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, bounds.minX), bounds.maxX) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, bounds.minY), bounds.maxY) }
        let x0 = clampX(rect.minX), x1 = clampX(rect.maxX)
        let y0 = clampY(rect.minY), y1 = clampY(rect.maxY)
        return CGRect(x: x0, y: y0, width: max(x1 - x0, 0), height: max(y1 - y0, 0)).insetBy(dx: -2, dy: -2)
    }

    // MARK: - Denoise

    /// Edge-aware denoise in Oklab: fine luminance + colour noise, then a wider colour pass
    /// for blotchy chroma noise. Runs on the decoded photo, before tone and colour.
    /// The photo is converted to Oklab once (not per tap), and the result is cached, so
    /// moving any other slider reuses it instead of denoising again.
    static func denoise(_ image: CIImage, amount: Double, detail: Double, cacheKey: String?) -> CIImage {
        guard amount > 0, let k = kernels else { return image }
        let e = image.extent
        guard !e.isEmpty, !e.isInfinite else { return image }
        // Thumbnails aren't cached (they'd push out the preview).
        let key = max(e.width, e.height) < 1200 ? nil
            : cacheKey.map { "\($0)|\(Int(e.width))x\(Int(e.height))|\(amount)|\(detail)" }
        if let key, let cached = DenoiseCache.shared.image(for: key) { return cached }

        let a = min(max(amount, 0), 100) / 100
        let keep = min(max(detail, 0), 100) / 100
        let h = (0.006 + 0.05 * pow(a, 1.3)) * (1.25 - 0.5 * keep)
        let hc = 0.01 + 0.07 * a
        guard let lab = DevelopKernel.run(k.toOklab, extent: e, arguments: [image]),
              // A lightly blurred guide makes the edge test robust to the noise itself.
              let guide = DevelopKernel.run(k.toOklab, extent: e, arguments: [
                  image.clampedToExtent().applyingGaussianBlur(sigma: 0.8).cropped(to: e),
              ])
        else { return image }

        func pass(_ input: CIImage, guide: CIImage, step: Double, chromaOnly: Bool) -> CIImage? {
            let reach = CGFloat(4 * step + 1)
            return DevelopKernel.run(k.denoise, extent: e, arguments: [
                input, guide,
                CIVector(x: CGFloat(h), y: CGFloat(hc), z: CGFloat(step), w: chromaOnly ? 1 : 0),
                CIVector(x: CGFloat(keep * 0.35), y: e.minX, z: e.maxX, w: 0),
                CIVector(x: e.minY, y: e.maxY, z: 0, w: 0),
            ], roi: { _, rect in rect.insetBy(dx: -reach, dy: -reach).intersection(e) })?.cropped(to: e)
        }

        guard let fine = pass(lab.cropped(to: e), guide: guide.cropped(to: e), step: 1, chromaOnly: false),
              let wide = pass(fine, guide: fine, step: 3, chromaOnly: true),
              let rgb = DevelopKernel.run(k.fromOklab, extent: e, arguments: [wide])?.cropped(to: e)
        else { return image }
        guard let key else { return rgb }
        return DenoiseCache.shared.store(rgb, for: key) ?? rgb
    }

    // MARK: - Lens Blur

    /// What sharp vs blurred is based on, for the panel.
    enum DepthSource {
        case depthMap, subject
    }

    static func depthSource(url: URL?) -> DepthSource {
        DepthMaps.shared.disparity(url: url) != nil ? .depthMap : .subject
    }

    static func applyLensBlur(_ s: LensBlurSettings, to image: CIImage, url: URL?) -> CIImage {
        guard s.isActive, let k = kernels else { return image }
        let e = image.extent
        let long = max(e.width, e.height)
        let radius = CGFloat(pow(min(max(s.amount, 0), 100) / 100, 1.2)) * 0.03 * long
        guard radius >= 1 else { return image }
        let edge = CGFloat(min(max(s.edge, 0), 100) / 100)

        // blurMap: how blurred each pixel should be (0 = sharp … 1 = full blur), already soft.
        // fillWeight: where the background colours may be taken from (1 = background).
        var blurMap: CIImage
        var fillWeight: CIImage
        if let depth = DepthMaps.shared.disparity(url: url) {
            let scaled = depth.image.transformed(by: CGAffineTransform(
                scaleX: e.width / depth.image.extent.width, y: e.height / depth.image.extent.height)
                .concatenating(CGAffineTransform(translationX: e.minX, y: e.minY)))
            let range = s.focusRange / 100 * 0.5
            guard let map = DevelopKernel.run(k.focus, extent: e, arguments: [
                scaled,
                CIVector(x: CGFloat(depth.minimum), y: CGFloat(1 / max(depth.maximum - depth.minimum, 1e-6)),
                         z: CGFloat(1 - s.focus / 100), w: CGFloat(range)),
            ]) else { return image }
            fillWeight = map.cropped(to: e)
            let edgeSigma = Double((0.002 + 0.012 * edge) * long)
            blurMap = fillWeight.clampedToExtent().applyingGaussianBlur(sigma: edgeSigma).cropped(to: e)
        } else if let mask = SubjectMaskStore.shared.mask(url: url, base: image) {
            guard let maps = subjectMaps(mask: mask, url: url, edge: edge, extent: e, kernels: k) else { return image }
            blurMap = maps.blur
            fillWeight = maps.fill
        } else {
            return image
        }

        // Fill the sharp area with the colours around it before blurring, so the subject
        // doesn't smear into the background (done small: it's all blur anyway).
        // Nearest background colours win: three blur sizes, the smallest one that found
        // enough background is used (one wide blur pulled bright walls into dark areas).
        let fillScale = min(1, 512 / long)
        guard let weighted = DevelopKernel.run(k.maskWeight, extent: e, arguments: [image, fillWeight])
        else { return image }
        let small = lanczos(weighted, scale: fillScale)
        let smallLong = max(small.extent.width, small.extent.height)
        func level(_ fraction: CGFloat) -> CIImage {
            small.clampedToExtent().applyingGaussianBlur(sigma: Double(fraction * smallLong)).cropped(to: small.extent)
        }
        guard let filledSmall = DevelopKernel.run(k.fill, extent: small.extent, arguments: [
            level(0.006), level(0.02), level(0.07),
        ]) else { return image }
        let filled = filledSmall.transformed(by: CGAffineTransform(scaleX: 1 / fillScale, y: 1 / fillScale))
            .clampedToExtent().cropped(to: e)
        guard let background = DevelopKernel.run(k.mix, extent: e, arguments: [filled, image, fillWeight]),
              let boosted = DevelopKernel.run(k.boost, extent: e, arguments: [background, NSNumber(value: s.boost / 100)])
        else { return image }

        let near = bokeh(boosted, radius: radius * 0.5, style: s.bokeh)
        let far = bokeh(boosted, radius: radius, style: s.bokeh)
        return DevelopKernel.run(k.lensMix, extent: e, arguments: [image, near, far, blurMap])?.cropped(to: e) ?? image
    }

    /// Subject (Select Subject) → soft blur map with a ground plane, and the fill weights.
    /// Worked at the mask's own size (≈1024 px), then scaled up: cheap at any photo size.
    private static func subjectMaps(mask: CGImage, url: URL?, edge: CGFloat, extent e: CGRect,
                                    kernels k: Kernels) -> (blur: CIImage, fill: CIImage)? {
        let subject = CIImage(cgImage: mask, options: [.colorSpace: NSNull()])
        let me = subject.extent
        let maskLong = max(me.width, me.height)
        guard maskLong > 0 else { return nil }

        func grow(_ image: CIImage, by px: CGFloat) -> CIImage {
            let filter = CIFilter.morphologyMaximum()
            filter.inputImage = image.clampedToExtent()
            filter.radius = Float(max(px, 1))
            return (filter.outputImage ?? image).cropped(to: me)
        }
        func toPhoto(_ image: CIImage) -> CIImage {
            image.transformed(by: CGAffineTransform(scaleX: e.width / me.width, y: e.height / me.height)
                .concatenating(CGAffineTransform(translationX: e.minX - me.minX * e.width / me.width,
                                                 y: e.minY - me.minY * e.height / me.height)))
                .clampedToExtent().cropped(to: e)
        }

        // Sharp zone: the subject grown a little, then feathered, so the change from sharp
        // to blurred happens just outside the subject's edge instead of on it.
        let sigma = Double((0.002 + 0.008 * edge) * maskLong)
        let sharp = grow(subject, by: 0.002 * maskLong)
            .clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: me)
        // Background colours for the fill: keep well away from the subject's edge.
        let fill = grow(subject, by: 0.006 * maskLong).applyingFilter("CIColorInvert")

        // Ground plane: the floor at the subject's feet stays sharp and blurs with distance.
        // Off when the subject runs off the bottom of the frame (portraits, close-ups).
        let bottom = SubjectGeometry.bottom(of: mask, url: url)
        let groundOn: CGFloat = (bottom.map { $0 > 0.02 } ?? false) ? 1 : 0
        let foot = me.minY + CGFloat(bottom ?? 0) * me.height
        let up = me.height * 0.4
        let down = max(foot - me.minY, me.height * 0.05)
        guard let blur = DevelopKernel.run(k.ground, extent: me, arguments: [
            sharp, CIVector(x: foot, y: up, z: down, w: 0.6), CIVector(x: groundOn, y: 0, z: 0, w: 0),
        ]) else { return nil }
        // A last light blur smooths the upscale from mask size to the photo.
        let smooth = blur.cropped(to: me).clampedToExtent().applyingGaussianBlur(sigma: 1).cropped(to: me)
        return (toPhoto(smooth), toPhoto(fill))
    }

    /// Bokeh blur, worked at a reduced size so the disc stays ≤ 24 px (fast at any radius).
    private static func bokeh(_ image: CIImage, radius: CGFloat, style: LensBlurSettings.Bokeh) -> CIImage {
        let e = image.extent
        let scale = min(1, 24 / max(radius, 1))
        let small = scale < 1 ? lanczos(image, scale: scale) : image
        let filter = CIFilter.bokehBlur()
        filter.inputImage = small.clampedToExtent()
        filter.radius = Float(radius * scale)
        switch style {
        case .circle:
            filter.ringAmount = 0
            filter.ringSize = 0.1
            filter.softness = 0.3
        case .bubble:
            filter.ringAmount = 0.55
            filter.ringSize = 0.12
            filter.softness = 0.2
        case .soft:
            filter.ringAmount = 0
            filter.ringSize = 0.1
            filter.softness = 1
        }
        guard let blurred = filter.outputImage?.cropped(to: small.extent) else { return image }
        guard scale < 1 else { return blurred }
        return blurred
            .transformed(by: CGAffineTransform(translationX: -small.extent.minX, y: -small.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: e.width / small.extent.width, y: e.height / small.extent.height))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
            .clampedToExtent()
            .cropped(to: e)
    }

    private static func lanczos(_ image: CIImage, scale: CGFloat) -> CIImage {
        guard scale < 1 else { return image }
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image
        filter.scale = Float(scale)
        filter.aspectRatio = 1
        return filter.outputImage ?? image
    }

    // MARK: - Kernels

    static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    inline float rtSmooth(float a, float b, float x) {
      float t = clamp((x - a) / max(b - a, 1e-5), 0.0, 1.0);
      return t * t * (3.0 - 2.0 * t);
    }

    inline float3 rtOklab(float3 c) {
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

    inline float3 rtFromOklab(float3 o) {
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

    // Healing ring weights: rgb = colour · w, alpha = w; w = 1 outside the circle
    // (g.xy, radius g.z), 0 inside.
    [[ stitchable ]] float4 rtRing(coreimage::sampler c, float4 g, coreimage::destination dest) {
      float2 dc = dest.coord();
      float4 p = c.sample(c.transform(dc));
      float w = clamp(distance(dc, g.xy) - g.z * 1.05, 0.0, 1.0);
      return float4(p.rgb * w, w);
    }

    // One spot: g = centre xy, radius, inner (fully covered) radius;
    // o.x opacity, o.y heal, o.zw = source − spot offset; b = photo bounds (minX, minY, maxX, maxY).
    // Heal keeps the source's texture but takes the light and colour of the ring around the
    // spot (added in a square-root space, which behaves well in darks and brights).
    [[ stitchable ]] float4 rtSpot(coreimage::sampler d, coreimage::sampler s, coreimage::sampler dl,
                                   coreimage::sampler sl, float4 g, float4 o, float4 b,
                                   coreimage::destination dest) {
      float2 dc = dest.coord();
      float4 dp = d.sample(d.transform(dc));
      float a = o.x * (1.0 - rtSmooth(g.w, g.z, distance(dc, g.xy)));
      if (a <= 0.0) { return dp; }
      float2 sc = clamp(dc + o.zw, b.xy + 0.5, b.zw - 0.5);
      float3 c = s.sample(s.transform(sc)).rgb;
      if (o.y > 0.5) {
        float4 lowD4 = dl.sample(dl.transform(dc));
        float4 lowS4 = sl.sample(sl.transform(sc));
        float3 lowD = lowD4.rgb / max(lowD4.a, 1e-5);
        float3 lowS = lowS4.rgb / max(lowS4.a, 1e-5);
        float3 e = sqrt(max(c, 0.0)) + sqrt(max(lowD, 0.0)) - sqrt(max(lowS, 0.0));
        e = max(e, 0.0);
        c = e * e;
      }
      return float4(mix(dp.rgb, c, a), dp.a);
    }

    [[ stitchable ]] float4 rtToOklab(coreimage::sample_t c) {
      return float4(rtOklab(c.rgb), 1.0);
    }

    [[ stitchable ]] float4 rtFromOklabK(coreimage::sample_t o) {
      return float4(max(rtFromOklab(o.rgb), 0.0), 1.0);
    }

    // Inputs are already Oklab. p: x = luminance range, y = colour range, z = tap spacing (px),
    // w = 1 colour only. q.x = share of the original luminance kept (Detail), q.yz = x bounds;
    // r.xy = y bounds (taps stay inside the photo).
    [[ stitchable ]] float4 rtDenoise(coreimage::sampler src, coreimage::sampler guide, float4 p, float4 q,
                                      float4 r, coreimage::destination dest) {
      float2 dc = dest.coord();
      float2 lo = float2(q.y, r.x) + 0.5;
      float2 hi = float2(q.z, r.y) - 0.5;
      float3 o0 = src.sample(src.transform(dc)).rgb;
      float3 g0 = guide.sample(guide.transform(dc)).rgb;
      float h2 = max(p.x * p.x, 1e-8);
      float hc2 = max(p.y * p.y, 1e-8);
      float accL = 0.0, wl = 0.0, wc = 0.0;
      float2 accC = float2(0.0);
      for (int j = -4; j <= 4; j++) {
        for (int i = -4; i <= 4; i++) {
          float2 at = clamp(dc + float2(float(i), float(j)) * p.z, lo, hi);
          float3 g = guide.sample(guide.transform(at)).rgb;
          float3 o = src.sample(src.transform(at)).rgb;
          float sp = exp(-float(i * i + j * j) / 18.0);
          float dl = g.x - g0.x;
          float2 dab = g.yz - g0.yz;
          float w1 = sp * exp(-(dl * dl + dot(dab, dab)) / h2);
          float w2 = sp * exp(-(dl * dl) / (4.0 * h2) - dot(dab, dab) / hc2);
          accL += o.x * w1; wl += w1;
          accC += o.yz * w2; wc += w2;
        }
      }
      float L = o0.x;
      if (p.w < 0.5) {
        L = mix(accL / max(wl, 1e-6), o0.x, q.x);
      }
      float2 ab = accC / max(wc, 1e-6);
      return float4(L, ab, 1.0);
    }

    // Lens blur fill weights: rgb = colour · w, alpha = w (w = red channel of m).
    [[ stitchable ]] float4 rtMaskWeight(coreimage::sample_t c, coreimage::sample_t m) {
      float w = clamp(m.r, 0.0, 1.0);
      return float4(c.rgb * w, w);
    }

    // Background fill from normalised blurs (rgb = Σ colour·w, a = Σ w), small → wide:
    // the smallest blur that has enough background weight decides the colour.
    [[ stitchable ]] float4 rtFill(coreimage::sample_t a, coreimage::sample_t b, coreimage::sample_t c) {
      float3 ca = a.rgb / max(a.a, 1e-4);
      float3 cb = b.rgb / max(b.a, 1e-4);
      float3 cc = c.rgb / max(c.a, 1e-4);
      float wa = rtSmooth(0.05, 0.3, a.a);
      float wb = rtSmooth(0.05, 0.3, b.a);
      float3 col = c.a > 1e-4 ? cc : cb;
      col = mix(col, cb, wb);
      col = mix(col, ca, wa);
      return float4(col, 1.0);
    }

    [[ stitchable ]] float4 rtNormalize(coreimage::sample_t n) {
      return float4(n.rgb / max(n.a, 1e-4), 1.0);
    }

    // Brightens highlights before the bokeh so they bloom into discs.
    [[ stitchable ]] float4 rtBoost(coreimage::sample_t c, float k) {
      float l = dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
      return float4(c.rgb * (1.0 + k * 4.0 * rtSmooth(0.55, 1.0, l)), c.a);
    }

    // a where m = 0, b where m = 1.
    [[ stitchable ]] float4 rtMix(coreimage::sample_t a, coreimage::sample_t b, coreimage::sample_t m) {
      return float4(mix(a.rgb, b.rgb, clamp(m.r, 0.0, 1.0)), 1.0);
    }

    // Sharp → half blur → full blur along t.
    [[ stitchable ]] float4 rtLensMix(coreimage::sample_t img, coreimage::sample_t near,
                                      coreimage::sample_t far, coreimage::sample_t t) {
      float x = clamp(t.r, 0.0, 1.0);
      float3 c = x < 0.5 ? mix(img.rgb, near.rgb, x * 2.0) : mix(near.rgb, far.rgb, x * 2.0 - 1.0);
      return float4(c, img.a);
    }

    // Depth map → blur amount. p: x = min disparity, y = 1 / (max − min), z = focus (1 = near), w = range.
    [[ stitchable ]] float4 rtFocus(coreimage::sample_t d, float4 p) {
      float n = clamp((d.r - p.x) * p.y, 0.0, 1.0);
      float t = rtSmooth(p.w, p.w + 0.25, abs(n - p.z));
      return float4(t, t, t, 1.0);
    }

    // Subject + ground plane → blur amount. sharp.r = feathered subject (1 = sharp).
    // p: x = feet height (y), y = distance up to full blur, z = distance down to `w` blur,
    // w = blur at the bottom edge (foreground floor blurs less). q.x = 1 ground plane on.
    [[ stitchable ]] float4 rtGround(coreimage::sampler sharp, float4 p, float4 q, coreimage::destination dest) {
      float2 dc = dest.coord();
      float subject = clamp(sharp.sample(sharp.transform(dc)).r, 0.0, 1.0);
      float y = dc.y;
      float t = y >= p.x ? rtSmooth(0.0, p.y, y - p.x) : p.w * rtSmooth(0.0, p.z, p.x - y);
      float depth = q.x > 0.5 ? t : 1.0;
      float b = (1.0 - subject) * depth;
      return float4(b, b, b, 1.0);
    }
    """
}

// MARK: - Rendered copies

/// Renders an image graph to a half-float bitmap and wraps it again, so later stages read
/// fixed pixels instead of re-running everything before them.
enum Materialized {
    private static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)

    static func image(_ image: CIImage) -> CIImage? {
        let e = image.extent
        guard !e.isEmpty, !e.isInfinite, let linear else { return nil }
        let bounds = e.integral
        guard let cg = DevelopRenderer.context.createCGImage(image, from: bounds, format: .RGBAh, colorSpace: linear)
        else { return nil }
        return CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
            .cropped(to: e)
    }
}

// MARK: - Base cache

/// The photo before the develop kernel (decode + denoise + profile), kept as rendered pixels
/// once the same base is asked for twice in a row — i.e. while a tone/colour slider moves.
/// A slider that changes the base itself (Temp, Tint, Detail, Profile) never fills it, so
/// those drags don't pay for an extra render.
final class BaseCache {
    static let shared = BaseCache()
    private static let maxPixels: CGFloat = 40_000_000

    private var entries: [(key: String, image: CIImage)] = []
    private var recent: [String] = []
    private let lock = NSLock()

    func image(for key: String?, build: () -> CIImage?) -> CIImage? {
        guard let key else { return build() }
        lock.lock()
        if let hit = entries.first(where: { $0.key == key }) {
            lock.unlock()
            return hit.image
        }
        let askedBefore = recent.contains(key)
        if !askedBefore {
            recent.append(key)
            if recent.count > 6 { recent.removeFirst(recent.count - 6) }
        }
        lock.unlock()

        guard let built = build() else { return nil }
        let e = built.extent
        guard askedBefore, max(e.width, e.height) >= 1200, e.width * e.height <= Self.maxPixels,
              let cached = Materialized.image(built) else { return built }
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.key == key }
        entries.insert((key, cached), at: 0)
        if entries.count > 2 { entries.removeLast(entries.count - 2) }
        return cached
    }
}

// MARK: - Denoise cache

/// The denoised photo, rendered once and reused while other sliders move.
/// Two entries: the preview size and the full size (zoom / export).
final class DenoiseCache {
    static let shared = DenoiseCache()
    /// Bigger photos aren't kept (memory): ≈ 8 bytes per pixel.
    private static let maxPixels: CGFloat = 40_000_000

    private var entries: [(key: String, image: CIImage)] = []
    private let lock = NSLock()
    func image(for key: String) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first { $0.key == key }?.image
    }

    /// Renders `image` to a bitmap and keeps it; returns the bitmap-backed image.
    func store(_ image: CIImage, for key: String) -> CIImage? {
        let e = image.extent
        guard e.width * e.height <= Self.maxPixels, let cached = Materialized.image(image) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.key == key }
        entries.insert((key, cached), at: 0)
        if entries.count > 2 { entries.removeLast(entries.count - 2) }
        return cached
    }
}

// MARK: - Subject geometry

enum SubjectGeometry {
    private static let cache = NSCache<NSString, NSNumber>()

    /// Height of the subject's lowest point (its feet), 0 = bottom edge … 1 = top,
    /// or nil when the mask is empty.
    static func bottom(of mask: CGImage, url: URL?) -> Double? {
        let key = url.map { "\($0.path)|\(Unmanaged.passUnretained(mask).toOpaque())|\(mask.width)x\(mask.height)" as NSString }
        if let key, let hit = cache.object(forKey: key) { return hit.doubleValue < 0 ? nil : hit.doubleValue }
        let w = mask.width, h = mask.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(mask, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        // Rows are stored top first. The lowest row with a real run of subject pixels.
        let needed = max(3, w / 300)
        var result: Double?
        for row in stride(from: h - 1, through: 0, by: -1) {
            var count = 0
            let base = row * w
            for x in 0..<w where pixels[base + x] > 127 { count += 1 }
            if count >= needed {
                result = Double(h - 1 - row) / Double(h)
                break
            }
        }
        if let key { cache.setObject(NSNumber(value: result ?? -1), forKey: key) }
        return result
    }
}

// MARK: - Depth maps (iPhone Portrait photos)

/// Embedded disparity maps (HEIC/JPEG from iPhone Portrait mode), normalised once per file.
final class DepthMaps {
    static let shared = DepthMaps()

    struct Map {
        let image: CIImage
        let minimum: Double
        let maximum: Double
    }

    private final class Box {
        let map: Map?
        init(_ map: Map?) { self.map = map }
    }

    private let cache = NSCache<NSString, Box>()
    private let lock = NSLock()
    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    func disparity(url: URL?) -> Map? {
        guard let url else { return nil }
        let key = url.path as NSString
        lock.lock()
        defer { lock.unlock() }
        if let box = cache.object(forKey: key) { return box.map }
        let map = load(url)
        cache.setObject(Box(map), forKey: key)
        return map
    }

    private func load(_ url: URL) -> Map? {
        // RAW files never carry one; skip the work.
        guard !FolderScanner.rawExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        var image = CIImage(contentsOf: url, options: [.auxiliaryDisparity: true, .applyOrientationProperty: true])
        if image == nil, let depth = CIImage(contentsOf: url, options: [.auxiliaryDepth: true, .applyOrientationProperty: true]) {
            image = depth.applyingFilter("CIDepthToDisparity")
        }
        guard var map = image, !map.extent.isEmpty, !map.extent.isInfinite else { return nil }
        map = map.transformed(by: CGAffineTransform(translationX: -map.extent.minX, y: -map.extent.minY))
        let filter = CIFilter.areaMinMaxRed()
        filter.inputImage = map
        filter.extent = map.extent
        guard let output = filter.outputImage else { return nil }
        var pixel = [Float](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
        // CIAreaMinMaxRed: red = minimum, green = maximum.
        let minimum = Double(pixel[0]), maximum = Double(pixel[1])
        guard maximum > minimum else { return nil }
        return Map(image: map, minimum: minimum, maximum: maximum)
    }
}
