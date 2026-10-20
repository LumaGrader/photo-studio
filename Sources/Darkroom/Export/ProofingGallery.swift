import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What goes into a client proofing gallery (File ▸ Create Proofing Gallery…).
struct ProofingOptions {
    var title: String
    /// "Photos by …" line, and who the client sends the picks to.
    var photographer: String
    var email: String
    /// Facebook / Messenger username for the m.me link (optional).
    var messenger: String
    /// Instructions shown above the photos (empty = the default text).
    var message: String
    var longEdge: Int
    var watermark: Bool
    var parentFolder: URL
}

/// Which catalog photo is number n in a gallery, so the client's picks can be matched back
/// even when several photos share a file name. Saved in Application Support/Darkroom/Proofing.
struct ProofingManifest: Codable, Identifiable {
    struct Entry: Codable {
        let n: Int
        let photoID: Int64
        let fileName: String
    }

    struct ImportedNote: Codable, Hashable {
        let n: Int
        let fileName: String
        let note: String
        let favorite: Bool
    }

    let id: String
    let title: String
    let created: Date
    let folderPath: String
    let entries: [Entry]
    /// From the last Import Client Picks.
    var client: String?
    var notes: [ImportedNote]?

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Darkroom/Proofing", isDirectory: true)
    }

    static func load(id: String) -> ProofingManifest? {
        let url = folder.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ProofingManifest.self, from: data)
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.folder.appendingPathComponent("\(id).json"), options: .atomic)
    }
}

enum ProofingError: LocalizedError {
    case noPhotos
    case folder(String)
    case allFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPhotos: return "Select the photos for the gallery first."
        case .folder(let reason): return "Couldn't create the gallery folder: \(reason)"
        case .allFailed(let reason): return "No photo could be exported. \(reason)"
        }
    }
}

/// Builds the gallery folder: index.html + photos/ (large JPEGs) + thumbs/, then a .zip of it.
enum ProofingGallery {
    struct Result {
        let folder: URL
        let zip: URL?
        let manifest: ProofingManifest
        let failures: [String]
    }

    static let thumbSize = 640

    /// Runs off the main thread. `progress` gets (done, total).
    static func build(photos: [Photo], options: ProofingOptions, watermark: WatermarkSettings,
                      progress: @escaping (Int, Int) -> Void) throws -> Result {
        guard !photos.isEmpty else { throw ProofingError.noPhotos }
        let fm = FileManager.default
        let id = String(format: "%08X", UInt32.random(in: 0...UInt32.max))
        let title = options.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = Exporter.sanitized(title.isEmpty ? "Proofing" : title) + " – Proofing"
        let folder = uniqueFolder(in: options.parentFolder, name: baseName)
        let photosDir = folder.appendingPathComponent("photos", isDirectory: true)
        let thumbsDir = folder.appendingPathComponent("thumbs", isDirectory: true)
        do {
            try fm.createDirectory(at: photosDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        } catch {
            throw ProofingError.folder(error.localizedDescription)
        }

        let exportOptions = ExportOptions(format: .jpeg, quality: 0.82, longEdge: options.longEdge,
                                          folder: photosDir, naming: .custom, customName: "Photo",
                                          stripLocation: true, watermark: watermark)
        var entries: [ProofingManifest.Entry] = []
        var items: [[String: Any]] = []
        var failures: [String] = []
        for (index, photo) in photos.enumerated() {
            let n = index + 1
            progress(index, photos.count)
            do {
                let url = try Exporter.export(photo, number: n, options: exportOptions)
                let file = url.lastPathComponent
                writeThumbnail(from: url, to: thumbsDir.appendingPathComponent(file))
                entries.append(.init(n: n, photoID: photo.id, fileName: photo.fileName))
                items.append(["n": n, "name": photo.displayName, "file": file])
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        progress(photos.count, photos.count)
        guard !entries.isEmpty else {
            try? fm.removeItem(at: folder)
            throw ProofingError.allFailed(failures.first ?? "")
        }

        let data: [String: Any] = [
            "id": id,
            "title": title.isEmpty ? "Proofing" : title,
            "photographer": options.photographer.trimmingCharacters(in: .whitespaces),
            "email": options.email.trimmingCharacters(in: .whitespaces),
            "messenger": messengerUsername(options.messenger),
            "message": options.message.trimmingCharacters(in: .whitespacesAndNewlines),
            "photos": items,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // "</script>" inside the data would end the script tag early.
        let safeJSON = json.replacingOccurrences(of: "</", with: "<\\/")
        let html = ProofingTemplate.html.replacingOccurrences(of: "/*GALLERY_DATA*/", with: safeJSON)
        do {
            try html.write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
            try readMe(title: title).write(to: folder.appendingPathComponent("Open index.html.txt"),
                                           atomically: true, encoding: .utf8)
        } catch {
            throw ProofingError.folder(error.localizedDescription)
        }

        let manifest = ProofingManifest(id: id, title: title.isEmpty ? "Proofing" : title, created: Date(),
                                        folderPath: folder.path, entries: entries)
        try? manifest.save()
        return Result(folder: folder, zip: zip(folder), manifest: manifest, failures: failures)
    }

    /// "facebook.com/rax.photos", "m.me/rax.photos", "@rax.photos" → "rax.photos".
    static func messengerUsername(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "www.", "m.me/", "facebook.com/", "fb.com/", "messenger.com/t/", "@"] {
            if s.lowercased().hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "."))
        return String(s.unicodeScalars.prefix { allowed.contains($0) })
    }

    private static func writeThumbnail(from source: URL, to target: URL) {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { return }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbSize,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary),
              let dest = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private static func uniqueFolder(in parent: URL, name: String) -> URL {
        var url = parent.appendingPathComponent(name, isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = parent.appendingPathComponent("\(name) (\(counter))", isDirectory: true)
            counter += 1
        }
        return url
    }

    /// Folder.zip next to the folder, for sending (Google Drive, Messenger, WeTransfer…).
    private static func zip(_ folder: URL) -> URL? {
        let zip = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".zip")
        try? FileManager.default.removeItem(at: zip)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, zip.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        return process.terminationStatus == 0 ? zip : nil
    }

    private static func readMe(title: String) -> String {
        """
        \(title.isEmpty ? "Your photos" : title)

        1. If this came as a .zip file, open it first (double-click on a computer,
           or tap it in the Files app on a phone) so you have the folder.
        2. Open index.html. It opens in your web browser; no internet needed.
        3. Tap the heart on the photos you like, and add a note if you want.
        4. Press "Send my picks" and send the list to your photographer.
        """
    }
}

/// A list pasted from the gallery's "Send my picks".
struct ProofingPicks: Equatable {
    struct Item: Equatable {
        let n: Int
        let name: String
        let note: String
        let favorite: Bool
    }

    var title: String?
    var galleryID: String?
    var client: String?
    var items: [Item] = []

    var favorites: [Item] { items.filter(\.favorite) }
    var notes: [Item] { items.filter { !$0.note.isEmpty } }
    var isEmpty: Bool { items.isEmpty }

    /// Lines like "#012 IMG_1209.CR3 — crop tighter". Lines after "Notes on other photos:"
    /// are notes on photos that weren't picked.
    static func parse(_ text: String) -> ProofingPicks {
        var result = ProofingPicks()
        var favorite = true
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.lowercased().hasPrefix("notes on other photos") { favorite = false; continue }
            if let value = field(line, "Gallery ID:") { result.galleryID = value.uppercased(); continue }
            if let value = field(line, "From:") { result.client = value == "(no name)" ? nil : value; continue }
            if let value = field(line, "LumaGrader picks ·") { result.title = value; continue }
            guard line.hasPrefix("#") else { continue }
            let body = line.dropFirst()
            let digits = body.prefix { $0.isNumber }
            guard let n = Int(digits), n > 0 else { continue }
            var rest = body.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
            var note = ""
            if let range = rest.range(of: " — ") {
                note = String(rest[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                rest = String(rest[..<range.lowerBound])
            }
            if !result.items.contains(where: { $0.n == n }) {
                result.items.append(Item(n: n, name: rest, note: note, favorite: favorite))
            }
        }
        return result
    }

    private static func field(_ line: String, _ prefix: String) -> String? {
        guard line.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
