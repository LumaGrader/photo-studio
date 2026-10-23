import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Developer tool for matching the sliders to Lightroom. Renders each test file with the
/// develop settings stored in its own XMP (the same files are imported into Lightroom),
/// so both apps start from identical pixels and identical slider values.
///
///   "/Applications/LumaGrader Photo Studio.app/Contents/MacOS/Darkroom" \
///       --calibrate <input folder> <output folder>
///
/// Every .tif/.jpg in the input folder is rendered at full size, without sharpening or
/// noise reduction, and saved to the output folder as a 16-bit sRGB TIFF with the same
/// name. No window opens; the app quits when done.
enum CalibrationRenderer {
    static let flag = "--calibrate"
    private static let imageExtensions: Set<String> = ["tif", "tiff", "jpg", "jpeg"]

    /// Runs and quits the process if the app was launched with `--calibrate`.
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag) else { return }
        guard arguments.count > index + 2 else {
            print("Usage: Darkroom \(flag) <input folder> <output folder>")
            exit(2)
        }
        let input = folderURL(arguments[index + 1])
        let output = folderURL(arguments[index + 2])
        exit(run(input: input, output: output) ? 0 : 1)
    }

    private static func folderURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func run(input: URL, output: URL) -> Bool {
        if case let .failure(error) = DevelopKernel.shared {
            print("✗ The develop kernel didn't compile: \(error.localizedDescription)")
            return false
        }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        } catch {
            print("✗ Can't create \(output.path): \(error.localizedDescription)")
            return false
        }
        let files = ((try? fileManager.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)) ?? [])
            .filter {
                let ext = $0.pathExtension.lowercased()
                return imageExtensions.contains(ext) || FolderScanner.rawExtensions.contains(ext)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            print("✗ No .tif or .jpg files in \(input.path)")
            return false
        }
        var allRendered = true
        for file in files {
            let target = output.appendingPathComponent(file.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("tif")
            if !render(file, to: target) { allRendered = false }
        }
        print(allRendered ? "✓ Done: \(files.count) files → \(output.path)" : "✗ Some files failed")
        return allRendered
    }

    /// The develop settings in a file's XMP, or in a sidecar `<name>.xmp` (RAW); defaults
    /// when there are none.
    static func settings(in file: URL) -> DevelopSettings {
        let sidecar = file.deletingPathExtension().appendingPathExtension("xmp")
        let data = (try? Data(contentsOf: sidecar)) ?? (try? Data(contentsOf: file))
        guard let data, let xmp = PresetImporter.extractXMP(from: data) else { return DevelopSettings() }
        let values = XMPPreset.parse(xmp)
        guard !values.scalars.isEmpty else { return DevelopSettings() }
        return PresetImporter.map(values).settings
    }

    private static func render(_ file: URL, to target: URL) -> Bool {
        // Sharpening and noise reduction come from the file's settings too (the kit files
        // set them to 0).
        let settings = settings(in: file)

        guard let source = DevelopRenderer.makeSource(url: file, maxPixel: nil),
              let image = DevelopRenderer.apply(settings, to: source, cube: ToneCubeCache())
        else {
            print("✗ \(file.lastPathComponent): couldn't render")
            return false
        }
        let extent = image.extent.integral
        guard let cgImage = DevelopRenderer.context.createCGImage(
            image, from: extent, format: .RGBA16, colorSpace: DevelopRenderer.sRGB),
              let destination = CGImageDestinationCreateWithURL(
                target as CFURL, UTType.tiff.identifier as CFString, 1, nil)
        else {
            print("✗ \(file.lastPathComponent): couldn't write \(target.lastPathComponent)")
            return false
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            print("✗ \(file.lastPathComponent): couldn't write \(target.lastPathComponent)")
            return false
        }
        let s = settings
        print(String(format: "✓ %@  Exp %+.2f  Con %+.0f  Hi %+.0f  Sh %+.0f  Wh %+.0f  Bl %+.0f  Sharp %.0f",
                     file.lastPathComponent, s.exposure, s.contrast, s.highlights, s.shadows, s.whites, s.blacks,
                     s.detail.effectiveSharpening(isRaw: FolderScanner.rawExtensions.contains(file.pathExtension.lowercased()))))
        return true
    }
}
