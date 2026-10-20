import Foundation
import CoreGraphics

/// An installed ICC profile for an RGB printer (paper profiles from Epson, Canon,
/// Hahnemühle, Canson, …).
struct PrinterProfile: Identifiable, Hashable {
    let url: URL
    let name: String
    var id: String { url.path }
}

/// Finds printer (output-class, RGB) ICC profiles in the standard ColorSync folders and in
/// the printer drivers' folders, and reads their names from the ICC header.
enum PrintProfiles {
    /// Where "Import Profile…" puts a profile (the usual place for downloaded paper profiles).
    static var userFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/ColorSync/Profiles", isDirectory: true)
    }

    private static var searchFolders: [URL] {
        [userFolder,
         URL(fileURLWithPath: "/Library/ColorSync/Profiles", isDirectory: true),
         URL(fileURLWithPath: "/Library/Printers", isDirectory: true),
         URL(fileURLWithPath: "/Network/Library/ColorSync/Profiles", isDirectory: true)]
    }

    /// Slow-ish (walks the driver folders): call off the main thread.
    static func scan() -> [PrinterProfile] {
        var found: [String: PrinterProfile] = [:]
        let fm = FileManager.default
        // Driver folders keep profiles inside bundles too (Canon, Epson), so packages are
        // walked as well.
        for folder in searchFolders where fm.fileExists(atPath: folder.path) {
            guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                let ext = url.pathExtension.lowercased()
                guard ext == "icc" || ext == "icm" else { continue }
                if let profile = read(url), found[profile.id] == nil {
                    found[profile.id] = profile
                }
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The profile if it is an RGB printer profile (device class 'prtr', colour space 'RGB ').
    static func read(_ url: URL) -> PrinterProfile? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 132), header.count == 132,
              fourCC(header, 36) == "acsp",
              fourCC(header, 12) == "prtr",
              fourCC(header, 16) == "RGB "
        else { return nil }
        let name = (try? Data(contentsOf: url)).flatMap(description) ?? url.deletingPathExtension().lastPathComponent
        return PrinterProfile(url: url, name: name)
    }

    /// The colour space to convert into, or nil when the file isn't a usable ICC profile.
    static func colorSpace(_ path: String) -> CGColorSpace? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return CGColorSpace(iccData: data as CFData)
    }

    // MARK: - ICC parsing

    private static func fourCC(_ data: Data, _ offset: Int) -> String {
        guard offset + 4 <= data.count else { return "" }
        let start = data.startIndex + offset
        return String(decoding: data[start..<start + 4], as: UTF8.self)
    }

    private static func uint32(_ data: Data, _ offset: Int) -> Int {
        guard offset + 4 <= data.count else { return 0 }
        let start = data.startIndex + offset
        return data[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
    }

    /// The 'desc' tag: ICC v2 'desc' (ASCII) or v4 'mluc' (UTF-16, first record).
    private static func description(_ data: Data) -> String? {
        let count = uint32(data, 128)
        guard count > 0, count < 200 else { return nil }
        for i in 0..<count {
            let entry = 132 + i * 12
            guard fourCC(data, entry) == "desc" else { continue }
            let offset = uint32(data, entry + 4)
            let size = uint32(data, entry + 8)
            guard offset > 0, size > 12, offset + size <= data.count else { return nil }
            let start = data.startIndex + offset
            switch fourCC(data, offset) {
            case "desc":
                let length = uint32(data, offset + 8)
                guard length > 1, 12 + length <= size else { return nil }
                let bytes = data[start + 12..<start + 12 + length - 1]
                return clean(String(decoding: bytes, as: UTF8.self))
            case "mluc":
                let records = uint32(data, offset + 8)
                guard records > 0 else { return nil }
                let length = uint32(data, offset + 20)
                let stringOffset = uint32(data, offset + 24)
                guard length > 0, stringOffset + length <= size else { return nil }
                let bytes = data[start + stringOffset..<start + stringOffset + length]
                var units: [UInt16] = []
                var index = bytes.startIndex
                while index + 1 < bytes.endIndex {
                    units.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
                    index += 2
                }
                return clean(String(decoding: units, as: UTF16.self))
            default:
                return nil
            }
        }
        return nil
    }

    private static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Copies a profile into ~/Library/ColorSync/Profiles. Returns it if it's a printer profile.
    static func importProfile(_ url: URL) throws -> PrinterProfile? {
        let fm = FileManager.default
        try fm.createDirectory(at: userFolder, withIntermediateDirectories: true)
        let target = userFolder.appendingPathComponent(url.lastPathComponent)
        if target.standardizedFileURL != url.standardizedFileURL {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: url, to: target)
        }
        return read(target)
    }
}
