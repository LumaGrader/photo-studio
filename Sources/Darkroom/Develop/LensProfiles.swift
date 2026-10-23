import Foundation
import CoreImage
import ImageIO

/// Lens vignetting corrections measured against Lightroom's lens profiles, for lenses the
/// macOS RAW decoder doesn't correct itself. Used when Lens Corrections is on (RAW default).
///
/// Vignetting is a gain in stops over the radius r (0 = centre, 1 = corner, normalised to the
/// half diagonal of the uncropped photo): gain = a·r² + b·r⁴, applied to the linear decode
/// before the base look. Fitted with tools/calibration (Oct 2026) jointly with the base
/// profiles; distortion (≈ 0.5 % at the corners) is not corrected yet.
enum LensProfiles {
    struct Profile {
        let name: String
        /// Matched case-insensitively against the EXIF lens model.
        let match: String
        let vignette: (a: Double, b: Double)
    }

    static let all: [Profile] = [
        // Canon R8 + RF 50 mm f/1.8 STM at f/1.8 (IMG_1085): +2.1 EV at the corners.
        Profile(name: "Canon RF50mm F1.8 STM", match: "rf50mm f1.8", vignette: (2.381, -0.245)),
    ]

    /// The profile for the lens a photo was taken with, if we have one.
    static func profile(for url: URL) -> Profile? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        guard let lens = (exif[kCGImagePropertyExifLensModel] as? String)
                ?? (aux[kCGImagePropertyExifAuxLensModel] as? String) else { return nil }
        let key = lens.lowercased().replacingOccurrences(of: " ", with: "")
        return all.first { key.contains($0.match.replacingOccurrences(of: " ", with: "")) }
    }

    private static let kernel: CIKernel? = {
        let source = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        // geo = (centre x, centre y, half diagonal, 0), coef = (a, b): gain = 2^(a·r² + b·r⁴).
        [[ stitchable ]] float4 lpVignette(coreimage::sampler src, float4 geo, float2 coef,
                                           coreimage::destination dest) {
          float4 px = src.sample(src.coord());
          float2 p = (dest.coord() - geo.xy) / geo.z;
          float r2 = dot(p, p);
          return float4(px.rgb * exp2(coef.x * r2 + coef.y * r2 * r2), px.a);
        }
        """
        return (try? CIKernel.kernels(withMetalString: source))?.first { $0.name == "lpVignette" }
    }()

    /// Applies the profile's vignetting correction to a linear RAW decode.
    static func correct(_ image: CIImage, profile: Profile) -> CIImage {
        guard let kernel else { return image }
        let e = image.extent
        guard !e.isInfinite, e.width > 0, e.height > 0 else { return image }
        let halfDiagonal = (e.width * e.width + e.height * e.height).squareRoot() / 2
        return kernel.apply(
            extent: e,
            roiCallback: { _, rect in rect },
            arguments: [
                image,
                CIVector(x: e.midX, y: e.midY, z: halfDiagonal, w: 0),
                CIVector(x: CGFloat(profile.vignette.a), y: CGFloat(profile.vignette.b)),
            ]) ?? image
    }
}
