import Foundation
import CoreImage
import AppKit
import UniformTypeIdentifiers

/// Darkroom looks (Standard, Vivid, Portrait…) and imported LUT profiles (.cube),
/// with an Amount (0–200 %), applied to the linear base rendering before the sliders.
enum ProfileRenderer {
    /// Look parameters: contrast (−1…1), saturation, per-colour saturation, hue shifts (°).
    struct Look {
        var contrast = 0.0
        var saturation = 1.0
        var warmSaturation = 1.0   // reds, oranges, skin
        var greenSaturation = 1.0
        var blueSaturation = 1.0
        var greenHue = 0.0         // + toward cyan, − toward yellow
        var blueHue = 0.0          // + toward purple, − toward cyan
        var monochrome = false
    }

    static func look(for profile: RawProfile) -> Look? {
        switch profile {
        case .darkroomColor, .adobeStandard, .cameraStandard, .cameraNeutral:
            return nil
        case .standard:
            return Look(contrast: 0.08, saturation: 1.04)
        case .vivid:
            return Look(contrast: 0.18, saturation: 1.22, greenSaturation: 1.1, blueSaturation: 1.1)
        case .portrait:
            return Look(contrast: 0.03, saturation: 0.97, warmSaturation: 0.9)
        case .landscape:
            return Look(contrast: 0.14, saturation: 1.1, greenSaturation: 1.18, blueSaturation: 1.15,
                        greenHue: -5, blueHue: -3)
        case .neutral:
            return Look(contrast: -0.14, saturation: 0.88)
        case .monochrome:
            return Look(contrast: 0.06, monochrome: true)
        }
    }

    private static let kernels: (look: CIKernel, mix: CIKernel)? = {
        guard let list = try? CIKernel.kernels(withMetalString: source),
              let look = list.first(where: { $0.name == "prLook" }),
              let mix = list.first(where: { $0.name == "prMix" })
        else { return nil }
        return (look, mix)
    }()

    static func apply(_ s: DevelopSettings, to image: CIImage) -> CIImage {
        let amount = min(max(s.profileAmount, 0), 200) / 100
        let lookParams = look(for: s.effectiveProfile)
        let cube = s.lutProfile.flatMap { ProfileLibrary.shared.cube(named: $0) }
        guard lookParams != nil || cube != nil, amount > 0, let k = kernels else { return image }
        let extent = image.extent
        var output = image
        if let p = lookParams {
            output = DevelopKernel.run(k.look, extent: extent, arguments: [
                output,
                CIVector(x: CGFloat(p.contrast), y: CGFloat(p.saturation), z: p.monochrome ? 1 : 0, w: 0),
                CIVector(x: CGFloat(p.warmSaturation), y: CGFloat(p.greenSaturation),
                         z: CGFloat(p.blueSaturation), w: 0),
                CIVector(x: CGFloat(p.greenHue), y: CGFloat(p.blueHue)),
            ])?.cropped(to: extent) ?? output
        }
        if let cube {
            let filter = CIFilter(name: "CIColorCubeWithColorSpace")
            filter?.setValue(output, forKey: kCIInputImageKey)
            filter?.setValue(cube.size, forKey: "inputCubeDimension")
            filter?.setValue(cube.data, forKey: "inputCubeData")
            filter?.setValue(CGColorSpace(name: CGColorSpace.sRGB), forKey: "inputColorSpace")
            if let result = filter?.outputImage { output = result.cropped(to: extent) }
        }
        guard abs(amount - 1) > 0.001 else { return output }
        return DevelopKernel.run(k.mix, extent: extent, arguments: [image, output, NSNumber(value: amount)])?
            .cropped(to: extent) ?? output
    }

    static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    inline float prSig(float x) { return 1.0 / (1.0 + exp(-x)); }
    inline float prEnc1(float v) { v = max(v, 0.0); return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055; }
    inline float prDec1(float v) { v = max(v, 0.0); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4); }
    inline float prLuma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
    inline float prSmooth(float a, float b, float x) { float t = clamp((x - a) / (b - a), 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }

    inline float3 prOklab(float3 c) {
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

    inline float3 prFromOklab(float3 o) {
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

    // Weight of a hue (degrees) within a band centred at c, half-width w.
    inline float prBand(float h, float c, float w) {
      float d = abs(fmod(h - c + 540.0, 360.0) - 180.0);
      return 1.0 - prSmooth(w * 0.5, w, d);
    }

    // a = (contrast, saturation, monochrome, 0), b = (warm, green, blue saturation),
    // c = (green hue shift, blue hue shift) in degrees.
    [[ stitchable ]] float4 prLook(coreimage::sample_t s, float4 a, float4 b, float2 c) {
      float3 lin = max(s.rgb, 0.0);
      float y = prLuma(lin);
      if (a.x != 0.0 && y > 1e-6) {
        // S-curve on encoded luminance around 0.45 (negative = flatter).
        float e = prEnc1(min(y, 1.0));
        float k = 5.0;
        float s0 = prSig(-k * 0.45), s1 = prSig(k * 0.55);
        float target = (prSig(k * (e - 0.45)) - s0) / (s1 - s0);
        float e2 = e + a.x * 2.0 * (target - e);
        if (y <= 1.0) lin *= prDec1(clamp(e2, 0.0, 1.0)) / y;
      }
      float3 o = prOklab(lin);
      if (a.z > 0.5) {
        o.yz = float2(0.0);
      } else {
        float chroma = length(o.yz);
        if (chroma > 1e-6) {
          float h = atan2(o.z, o.y) * 57.29577951;
          if (h < 0.0) h += 360.0;
          float warm = prBand(h, 45.0, 55.0);
          float green = prBand(h, 140.0, 45.0);
          float blue = prBand(h, 255.0, 45.0);
          float gain = a.y * mix(1.0, b.x, warm) * mix(1.0, b.y, green) * mix(1.0, b.z, blue);
          h += c.x * green + c.y * blue;
          float hr = h * 0.01745329252;
          o.yz = float2(cos(hr), sin(hr)) * chroma * gain;
        }
      }
      return float4(max(prFromOklab(o), 0.0), s.a);
    }

    // a + (b − a) · t  (t up to 2 extrapolates for Amount > 100 %).
    [[ stitchable ]] float4 prMix(coreimage::sample_t a, coreimage::sample_t b, float t) {
      return float4(max(a.rgb + (b.rgb - a.rgb) * t, 0.0), b.a);
    }
    """
}

/// Imported LUT profiles: .cube files copied into ~/Library/Application Support/Darkroom/Profiles.
final class ProfileLibrary: ObservableObject {
    static let shared = ProfileLibrary()

    struct Cube {
        let size: Int
        let data: Data
    }

    @Published private(set) var names: [String] = []

    private var cache: [String: Cube] = [:]
    private let lock = NSLock()

    let folder: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let url = base.appendingPathComponent("Darkroom/Profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init() {
        reload()
    }

    func reload() {
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return }
        names = files.filter { $0.pathExtension.lowercased() == "cube" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Parsed 3D LUT (thread-safe, cached).
    func cube(named name: String) -> Cube? {
        lock.lock()
        defer { lock.unlock() }
        if let cube = cache[name] { return cube }
        guard let url = folder?.appendingPathComponent(name + ".cube"),
              let text = try? String(contentsOf: url, encoding: .utf8) ?? String(contentsOf: url, encoding: .isoLatin1),
              let cube = Self.parse(text) else { return nil }
        cache[name] = cube
        return cube
    }

    /// Copies .cube files in. Returns the names added and the files that failed.
    @MainActor
    func importFiles(_ urls: [URL]) -> (added: [String], failed: [String]) {
        guard let folder else { return ([], urls.map(\.lastPathComponent)) }
        var added: [String] = [], failed: [String] = []
        for url in urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8), Self.parse(text) != nil else {
                failed.append(url.lastPathComponent)
                continue
            }
            let name = url.deletingPathExtension().lastPathComponent
            let target = folder.appendingPathComponent(name + ".cube")
            try? FileManager.default.removeItem(at: target)
            do {
                try FileManager.default.copyItem(at: url, to: target)
                lock.lock()
                cache[name] = nil
                lock.unlock()
                added.append(name)
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        reload()
        return (added, failed)
    }

    @MainActor
    func chooseAndImport() -> (added: [String], failed: [String])? {
        let panel = NSOpenPanel()
        panel.title = "Import LUT Profiles"
        panel.message = "Choose 3D LUT files (.cube)"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if let cube = UTType(filenameExtension: "cube") { panel.allowedContentTypes = [cube] }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        return importFiles(panel.urls)
    }

    @MainActor
    func remove(_ name: String) {
        guard let url = folder?.appendingPathComponent(name + ".cube") else { return }
        try? FileManager.default.removeItem(at: url)
        lock.lock()
        cache[name] = nil
        lock.unlock()
        reload()
    }

    /// Reads a 3D .cube LUT (LUT_3D_SIZE + rows of "r g b", red changing fastest).
    static func parse(_ text: String) -> Cube? {
        var size = 0
        var values: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = parts.first else { continue }
            if first == "LUT_3D_SIZE", parts.count > 1 {
                size = Int(parts[1]) ?? 0
            } else if first == "LUT_1D_SIZE" {
                return nil // 1D LUTs aren't supported
            } else if first.hasPrefix("DOMAIN_") || first == "TITLE" {
                continue // inputs are assumed 0…1 (the usual case)
            } else if parts.count >= 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) {
                values.append(contentsOf: [r, g, b, 1])
            }
        }
        guard size >= 2, size <= 128, values.count == size * size * size * 4 else { return nil }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return Cube(size: size, data: data)
    }
}
