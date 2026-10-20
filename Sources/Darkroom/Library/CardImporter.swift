import Foundation
import AppKit

/// Import from a memory card (or any folder): copy into a folder per shoot, rename
/// Date_Shoot_0001, make a backup copy on another drive, skip what was imported before.
struct ImportOptions {
    /// e.g. ~/Pictures. Photos go to <base>/<year>/<date> <shoot>/.
    var baseFolder: URL
    var shootName = ""
    var rename = true
    /// Second copy (same folder layout) on another drive; nil = no backup.
    var backupFolder: URL?
    var skipDuplicates = true
    var ejectWhenDone = false
    var presetID: Int64?
    var creator = ""
    var copyright = ""
    var keywords = ""
}

enum CardImporter {
    struct Source: Identifiable, Hashable {
        let url: URL
        let name: String
        /// A camera card (has DCIM) rather than a folder picked by hand.
        let isCard: Bool
        var id: URL { url }
    }

    struct Item {
        let source: URL
        let size: Int64
        let date: Date
        let signature: String
        var destinationName: String
    }

    struct Plan {
        var items: [Item]
        var skipped: Int
        var folder: URL
        var backup: URL?
        var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
        var dateRange: (Date, Date)? {
            guard let first = items.map(\.date).min(), let last = items.map(\.date).max() else { return nil }
            return (first, last)
        }
    }

    struct Result {
        let folder: URL
        let copied: [URL]
        let signatures: [String]
        let failed: [String]
        let backupFailed: [String]
    }

    // MARK: - Sources

    /// Mounted cards: removable or ejectable volumes with a DCIM folder.
    static func cards() -> [Source] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                            options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { volume in
            let dcim = volume.appendingPathComponent("DCIM", isDirectory: true)
            guard FileManager.default.fileExists(atPath: dcim.path) else { return nil }
            let name = (try? volume.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? volume.lastPathComponent
            return Source(url: dcim, name: name, isCard: true)
        }
    }

    static func signature(name: String, size: Int64, date: Date) -> String {
        "\(name)|\(size)|\(Int(date.timeIntervalSince1970))"
    }

    // MARK: - Plan

    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "Game vs Tigers" → "Game-vs-Tigers" (safe in file names).
    static func fileSafe(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined()
        return cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: "-")
    }

    static func folderName(date: Date, shoot: String) -> String {
        let day = dayFormat.string(from: date)
        let name = shoot.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined()
        return name.isEmpty ? day : "\(day) \(name)"
    }

    static func plan(files: [ScannedFile], options: ImportOptions, alreadyImported: Set<String>) -> Plan {
        // Oldest first; RAW + JPEG of one shot share a number.
        let sorted = files.sorted { ($0.modified, $0.url.lastPathComponent) < ($1.modified, $1.url.lastPathComponent) }
        var items: [Item] = []
        var skipped = 0
        for file in sorted {
            let signature = signature(name: file.url.lastPathComponent, size: file.size, date: file.modified)
            if options.skipDuplicates, alreadyImported.contains(signature) {
                skipped += 1
                continue
            }
            items.append(Item(source: file.url, size: file.size, date: file.modified, signature: signature,
                              destinationName: file.url.lastPathComponent))
        }
        let shootDate = items.map(\.date).min() ?? Date()
        let year = Calendar(identifier: .gregorian).component(.year, from: shootDate)
        let relative = "\(year)/\(folderName(date: shootDate, shoot: options.shootName))"
        let folder = options.baseFolder.appendingPathComponent(relative, isDirectory: true)
        let backup = options.backupFolder?.appendingPathComponent(relative, isDirectory: true)

        if options.rename {
            let prefix = [dayFormat.string(from: shootDate), fileSafe(options.shootName)]
                .filter { !$0.isEmpty }.joined(separator: "_") + "_"
            var number = nextNumber(in: folder, prefix: prefix)
            var numberForStem: [String: Int] = [:]
            for i in items.indices {
                let source = items[i].source
                let stem = source.deletingPathExtension().lastPathComponent.lowercased()
                let n: Int
                if let existing = numberForStem[stem] {
                    n = existing
                } else {
                    n = number
                    numberForStem[stem] = n
                    number += 1
                }
                items[i].destinationName = prefix + String(format: "%04d", n) + "." + source.pathExtension
            }
        }
        return Plan(items: items, skipped: skipped, folder: folder, backup: backup)
    }

    /// Continues numbering after files already in the folder (importing a second card).
    private static func nextNumber(in folder: URL, prefix: String) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let highest = names.compactMap { name -> Int? in
            guard name.hasPrefix(prefix) else { return nil }
            let rest = name.dropFirst(prefix.count).prefix { $0.isNumber }
            return Int(rest)
        }.max() ?? 0
        return highest + 1
    }

    // MARK: - Copy

    /// Copies (never moves) every file; returns what was copied. `isCancelled` is checked
    /// between files; `progress(done)` reports files finished.
    static func run(_ plan: Plan, isCancelled: () -> Bool, progress: (Int) -> Void) -> Result {
        let fm = FileManager.default
        var copied: [URL] = []
        var signatures: [String] = []
        var failed: [String] = []
        var backupFailed: [String] = []
        do {
            try fm.createDirectory(at: plan.folder, withIntermediateDirectories: true)
        } catch {
            return Result(folder: plan.folder, copied: [], signatures: [],
                          failed: plan.items.map { $0.source.lastPathComponent }, backupFailed: [])
        }
        var backupReady = false
        if let backup = plan.backup {
            backupReady = (try? fm.createDirectory(at: backup, withIntermediateDirectories: true)) != nil
        }
        for (index, item) in plan.items.enumerated() {
            if isCancelled() { break }
            let target = uniqueURL(plan.folder.appendingPathComponent(item.destinationName))
            do {
                try fm.copyItem(at: item.source, to: target)
                let size = (try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
                guard Int64(size) == item.size else {
                    try? fm.removeItem(at: target)
                    throw CocoaError(.fileWriteUnknown)
                }
                // Keep the capture time as the file date (sorting, re-import detection).
                try? fm.setAttributes([.modificationDate: item.date], ofItemAtPath: target.path)
                copied.append(target)
                signatures.append(item.signature)
            } catch {
                failed.append(item.source.lastPathComponent)
            }
            if let backup = plan.backup {
                if backupReady {
                    let backupTarget = uniqueURL(backup.appendingPathComponent(target.lastPathComponent))
                    if (try? fm.copyItem(at: item.source, to: backupTarget)) == nil {
                        backupFailed.append(item.source.lastPathComponent)
                    }
                } else {
                    backupFailed.append(item.source.lastPathComponent)
                }
            }
            progress(index + 1)
        }
        return Result(folder: plan.folder, copied: copied, signatures: signatures,
                      failed: failed, backupFailed: backupFailed)
    }

    private static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 2
        var candidate = url
        repeat {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }

    /// Ejects the card the source folder is on.
    static func eject(_ source: URL) {
        guard let volume = try? source.resourceValues(forKeys: [.volumeURLKey]).volume else { return }
        try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)
    }
}
