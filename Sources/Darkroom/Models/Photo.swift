import Foundation
import CoreGraphics

enum Flag: Int {
    case reject = -1
    case unflagged = 0
    case pick = 1
}

/// Colour label, like Lightroom's (keys 6–9; Purple from the menus only).
enum ColorLabel: Int, CaseIterable, Identifiable {
    case none = 0
    case red = 1
    case yellow = 2
    case green = 3
    case blue = 4
    case purple = 5

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .none: return "None"
        case .red: return "Red"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        }
    }

    /// The number key that sets it (nil = menus only).
    var key: Int? {
        switch self {
        case .red: return 6
        case .yellow: return 7
        case .green: return 8
        case .blue: return 9
        case .none, .purple: return nil
        }
    }

    static func forKey(_ key: Int) -> ColorLabel? { allCases.first { $0.key == key } }

    /// Every real label (not None).
    static var colors: [ColorLabel] { allCases.filter { $0 != .none } }
}

/// A named person (People).
struct Person: Identifiable, Hashable {
    let id: Int64
    var name: String
    var faceCount: Int
}

/// A face found in a photo, as stored in the catalog.
struct FaceRecord: Identifiable, Hashable {
    let id: Int64
    let photoID: Int64
    /// Upright, uncropped photo, 0…1 from the top-left.
    let rect: CGRect
    /// Archived Vision feature print (for "who looks alike").
    let print: Data?
    /// Small JPEG of the face.
    let thumb: Data?
    var personID: Int64?
    let path: String
}

/// A face just found by the scanner (not saved yet).
struct DetectedFace {
    let rect: CGRect
    let print: Data?
    let thumb: Data?
}

struct PhotoCollection: Identifiable, Hashable {
    let id: Int64
    var name: String
    var count: Int
}

/// A saved version of a photo's settings (Snapshots panel).
struct Snapshot: Identifiable, Hashable {
    let id: Int64
    var name: String
    var settings: DevelopSettings
}

struct Folder: Identifiable, Hashable {
    let id: Int64
    let url: URL

    var name: String { url.lastPathComponent }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
}

/// Your own information about a photo (Metadata panel); written into exported files.
struct PhotoMeta: Codable, Hashable {
    var title = ""
    var caption = ""
    var creator = ""
    var copyright = ""
    var keywords: [String] = []

    var isEmpty: Bool { self == PhotoMeta() }

    init() {}

    private enum CodingKeys: String, CodingKey { case title, caption, creator, copyright, keywords }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        caption = (try? c.decodeIfPresent(String.self, forKey: .caption)) ?? ""
        creator = (try? c.decodeIfPresent(String.self, forKey: .creator)) ?? ""
        copyright = (try? c.decodeIfPresent(String.self, forKey: .copyright)) ?? ""
        keywords = (try? c.decodeIfPresent([String].self, forKey: .keywords)) ?? []
    }

    func jsonString() -> String? {
        guard !isEmpty, let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func from(json: String?) -> PhotoMeta {
        guard let json, let data = json.data(using: .utf8),
              let meta = try? JSONDecoder().decode(PhotoMeta.self, from: data) else { return PhotoMeta() }
        return meta
    }

    /// "a, b, c" → keywords (trimmed, no duplicates, order kept).
    static func keywords(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

/// What the Mac's AI found in a photo (AI Cull).
struct PhotoAnalysis: Hashable {
    /// Vision aesthetics score, −1…1 (nil on macOS before 15).
    var aesthetic: Double?
    /// Screenshots, documents, receipts…
    var utility: Bool
    /// Detail in the sharpest part of the photo, 0…1.
    var sharpness: Double
    var faces: Int
    /// Number of faces whose eyes look closed.
    var eyesClosed: Int
    /// Feature-print distance to the previous photo in the folder (similar shots are close).
    var distanceToPrevious: Double?

    var isBlurry: Bool { sharpness < 0.28 }

    /// 0…1, the overall pick-worthiness used for ranking and stars.
    var score: Double {
        var s = 0.5
        if let aesthetic { s = 0.25 + 0.5 * (aesthetic + 1) / 2 } // 0.25…0.75
        s += (sharpness - 0.5) * 0.4
        if eyesClosed > 0 { s -= 0.25 }
        if utility { s -= 0.3 }
        return min(max(s, 0), 1)
    }

    /// 1…5 stars from the score.
    var stars: Int { min(5, max(1, Int((score * 5).rounded(.up)))) }
}

struct Photo: Identifiable, Hashable {
    let id: Int64
    let folderID: Int64
    let url: URL
    let fileName: String
    var rating: Int
    var flag: Flag
    var label: ColorLabel = .none
    var develop: DevelopSettings
    var meta = PhotoMeta()
    /// 0 = the photo itself, 1… = virtual copies of the same file.
    var copyIndex = 0

    var isVirtualCopy: Bool { copyIndex > 0 }

    /// File name, plus "Copy n" for virtual copies.
    var displayName: String { isVirtualCopy ? "\(fileName) · Copy \(copyIndex)" : fileName }

    var isRaw: Bool {
        FolderScanner.rawExtensions.contains(url.pathExtension.lowercased())
    }

    var hasEdits: Bool { !develop.isDefault }

    /// Same folder + same name without extension, e.g. ".../IMG_0519".
    var stemKey: String {
        url.deletingPathExtension().path.lowercased()
    }
}
