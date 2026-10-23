import Foundation
import CoreImage
import ImageIO

/// Lens vignetting corrections measured against Lightroom's lens profiles, for lenses the
/// macOS RAW decoder doesn't correct itself. Used when Lens Corrections is on (RAW default).
///
/// Vignetting is a gain in stops over the radius r (0 = centre, 1 = corner, normalised to the
/// half diagonal of the uncropped photo): gain = a·r² + b·r⁴, applied to the linear decode
/// before the base look. Like Lightroom's profiles it depends on the focus distance (stronger
/// when focused far): measured at two distances and interpolated over 1/distance. Fitted with
/// tools/calibration (Oct 2026) jointly with the base profiles; distortion (≈ 0.5 % at the
/// corners) is not corrected yet.
enum LensProfiles {
    struct Vignette {
        /// Focus distance in metres the coefficients were measured at.
        let distance: Double
        let a: Double
        let b: Double
    }

    struct Profile {
        let name: String
        /// Matched case-insensitively against the EXIF lens model (spaces and "/" ignored).
        let match: String
        let near: Vignette
        let far: Vignette
        /// Coefficients for this photo (set by `profile(for:)`; `near` when the distance is unknown).
        var vignette: (a: Double, b: Double)

        init(name: String, match: String, near: Vignette, far: Vignette) {
            self.name = name
            self.match = match
            self.near = near
            self.far = far
            vignette = (near.a, near.b)
        }

        /// Interpolated over 1/distance between `near` and `far`, up to infinity; closer than
        /// `near` keeps `near`.
        func interpolatedVignette(focusDistance d: Double) -> (a: Double, b: Double) {
            let span = 1 / near.distance - 1 / far.distance
            guard d > 0, span > 0 else { return (near.a, near.b) }
            let t = min(max((1 / near.distance - 1 / d) / span, 0), 1 / near.distance / span)
            return (near.a + (far.a - near.a) * t, near.b + (far.b - near.b) * t)
        }
    }

    static let all: [Profile] = [
        // Canon R8 + EF 50 mm f/1.8 STM (adapted) at f/1.8: IMG_1085 focused at 1.7 m
        // (+2.1 EV at the corners), IMG_1025 at 6 m (+3.0 EV).
        Profile(name: "Canon EF50mm f/1.8 STM", match: "ef50mm f1.8 stm",
                near: Vignette(distance: 1.70, a: 2.381, b: -0.245),
                far: Vignette(distance: 6.05, a: 3.341, b: -0.347)),
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
        func normalized(_ text: String) -> String {
            text.lowercased().filter { $0 != " " && $0 != "/" }
        }
        let key = normalized(lens)
        guard var profile = all.first(where: { key.contains(normalized($0.match)) }) else { return nil }
        if let distance = CanonFocusDistance.read(url) {
            profile.vignette = profile.interpolatedVignette(focusDistance: distance)
        }
        return profile
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

/// Focus distance of a Canon CR3: the mean of FocusDistanceUpper/Lower (cm) in the maker
/// notes' FileInfo (tag 0x0093, entries 20 and 21), stored in the CMT3 box. ImageIO doesn't
/// expose it. Returns nil for other files or when the camera didn't record it.
enum CanonFocusDistance {
    private static let canonUUID: [UInt8] = [0x85, 0xc0, 0xb6, 0x87, 0x82, 0x0f, 0x11, 0xe0,
                                             0x81, 0x11, 0xf4, 0xce, 0x46, 0x2b, 0x6a, 0x48]

    static func read(_ url: URL) -> Double? {
        guard url.pathExtension.lowercased() == "cr3",
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1 << 20) else { return nil }
        let bytes = [UInt8](data)
        guard let moov = box("moov", in: bytes, from: 0, to: bytes.count),
              let canon = uuidBox(in: bytes, from: moov.start, to: moov.end),
              let cmt3 = box("CMT3", in: bytes, from: canon.start + 16, to: canon.end)
        else { return nil }
        let tiff = Array(bytes[cmt3.start..<cmt3.end])
        guard let info = shorts(tag: 0x0093, in: tiff), info.count > 21 else { return nil }
        let upper = Double(info[20]), lower = Double(info[21])
        guard upper > 0, lower > 0, upper < 65535, lower < 65535 else { return nil }
        return (upper + lower) / 200
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }

    /// Payload range of the first ISO-BMFF box of `type` between `from` and `to`.
    private static func box(_ type: String, in b: [UInt8], from: Int, to: Int) -> (start: Int, end: Int)? {
        let want = Array(type.utf8)
        var offset = from
        while offset + 8 <= to {
            var size = be32(b, offset)
            var header = 8
            if size == 1, offset + 16 <= to {
                size = be32(b, offset + 12)  // 64-bit size; boxes we read are small
                header = 16
            } else if size == 0 {
                size = to - offset
            }
            guard size >= header else { return nil }
            if Array(b[(offset + 4)..<(offset + 8)]) == want {
                return (offset + header, min(offset + size, to))
            }
            offset += size
        }
        return nil
    }

    private static func uuidBox(in b: [UInt8], from: Int, to: Int) -> (start: Int, end: Int)? {
        var offset = from
        while let found = box("uuid", in: b, from: offset, to: to) {
            if found.start + 16 <= found.end, Array(b[found.start..<(found.start + 16)]) == canonUUID {
                return found
            }
            offset = found.end
        }
        return nil
    }

    /// Values of an SSHORT/SHORT array tag in the first IFD of a TIFF block.
    private static func shorts(tag: Int, in t: [UInt8]) -> [Int]? {
        guard t.count >= 8 else { return nil }
        let little = t[0] == 0x49
        func u16(_ i: Int) -> Int {
            little ? Int(t[i]) | Int(t[i + 1]) << 8 : Int(t[i]) << 8 | Int(t[i + 1])
        }
        func u32(_ i: Int) -> Int {
            little ? u16(i) | u16(i + 2) << 16 : u16(i) << 16 | u16(i + 2)
        }
        let ifd = u32(4)
        guard ifd + 2 <= t.count else { return nil }
        let count = u16(ifd)
        for i in 0..<count {
            let entry = ifd + 2 + 12 * i
            guard entry + 12 <= t.count else { return nil }
            guard u16(entry) == tag else { continue }
            let n = u32(entry + 4)
            let start = n * 2 > 4 ? u32(entry + 8) : entry + 8
            guard start + n * 2 <= t.count else { return nil }
            return (0..<n).map { u16(start + 2 * $0) }
        }
        return nil
    }
}
