import Foundation

struct ScannedFile {
    let url: URL
    let size: Int64
    let modified: Date
}

/// Finds photo files in a folder and its subfolders (hidden files skipped).
enum FolderScanner {
    static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2",
        "raf", "rw2", "orf", "pef", "srw", "x3f", "3fr", "iiq", "erf", "mos", "rwl",
    ]

    static let imageExtensions: Set<String> = rawExtensions.union([
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp",
    ])

    static func scan(_ folder: URL) throws -> [ScannedFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        var files: [ScannedFile] = []
        for case let url as URL in enumerator {
            guard imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            files.append(ScannedFile(
                url: url,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate ?? .distantPast))
        }
        return files
    }
}
