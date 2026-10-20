import Foundation
import SQLite3

/// Copies of Catalog.sqlite — ratings, flags, labels, edits, collections, people.
///
/// A backup is made with `VACUUM INTO` on its own connection, so it is a consistent copy
/// even while the app is writing, and it runs off the main thread. Each copy is checked
/// with `PRAGMA quick_check` before it counts. Only the newest `keep` copies are kept.
///
/// Restore can't swap the open database, so it is staged: the chosen backup is recorded,
/// the app quits and relaunches, and `applyPendingRestore` swaps it in before the catalog
/// opens. The replaced catalog is kept as "Catalog before restore.sqlite".
enum CatalogBackup {
    enum Keys {
        static let folder = "backup.folder"
        static let auto = "backup.auto"
        static let last = "backup.last"
        static let pendingRestore = "backup.pendingRestore"
    }

    static let keep = 10
    static let autoInterval: TimeInterval = 24 * 60 * 60
    private static let prefix = "Catalog "
    private static let suffix = ".sqlite"

    enum BackupError: LocalizedError {
        case sqlite(String)
        case check(String)

        var errorDescription: String? {
            switch self {
            case .sqlite(let message): return "Backup failed: \(message)"
            case .check(let message): return "The backup didn't pass its check (\(message)). Your catalog is unchanged."
            }
        }
    }

    // MARK: - Settings

    /// ~/Library/Application Support/Darkroom/Backups
    static var defaultFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Darkroom/Backups", isDirectory: true)
    }

    /// The chosen folder (e.g. on another drive), or the default.
    static var folder: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: Keys.folder), !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return defaultFolder
        }
        set { UserDefaults.standard.set(newValue.path, forKey: Keys.folder) }
    }

    static var isCustomFolder: Bool {
        !(UserDefaults.standard.string(forKey: Keys.folder) ?? "").isEmpty
    }

    /// Daily automatic backup; off until turned on (File ▸ Catalog Backup ▸ Back Up Daily).
    static var autoEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Keys.auto) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: Keys.auto) }
    }

    static var lastBackup: Date? {
        get { UserDefaults.standard.object(forKey: Keys.last) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Keys.last) }
    }

    static var isDue: Bool {
        guard autoEnabled else { return false }
        guard let last = lastBackup else { return true }
        return Date().timeIntervalSince(last) >= autoInterval
    }

    // MARK: - Backup

    /// Writes a checked copy of `catalog` into `folder` and prunes old copies.
    /// Thread-safe; call off the main thread.
    @discardableResult
    static func run(catalog: URL, to folder: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let target = folder.appendingPathComponent(prefix + formatter.string(from: Date()) + suffix)
        // A half-written file from an earlier failure would make VACUUM INTO fail.
        let partial = target.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)

        var db: OpaquePointer?
        guard sqlite3_open_v2(catalog.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open the catalog"
            sqlite3_close(db)
            throw BackupError.sqlite(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)

        let literal = partial.path.replacingOccurrences(of: "'", with: "''")
        if sqlite3_exec(db, "VACUUM INTO '\(literal)';", nil, nil, nil) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            try? fm.removeItem(at: partial)
            throw BackupError.sqlite(message)
        }

        do {
            try check(partial)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        try? fm.removeItem(at: target)
        try fm.moveItem(at: partial, to: target)

        lastBackup = Date()
        prune(folder)
        return target
    }

    /// Runs `PRAGMA quick_check` on a copy.
    static func check(_ url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw BackupError.check("can't open the copy")
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check;", -1, &stmt, nil) == SQLITE_OK else {
            throw BackupError.check(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else {
            throw BackupError.check("no result")
        }
        let result = String(cString: text)
        guard result == "ok" else { throw BackupError.check(result) }
    }

    /// The backups in `folder`, newest first. Only files this app made are listed.
    static func list(in folder: URL = folder) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
            .sorted(by: >) // the date in the name sorts chronologically
            .map { folder.appendingPathComponent($0) }
    }

    private static func prune(_ folder: URL) {
        for old in list(in: folder).dropFirst(keep) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    /// The automatic backup: to the chosen folder, or the default one when that folder
    /// isn't there (an unplugged drive). Returns nil when nothing was due or it failed.
    static func runAutoIfDue(catalog: URL) -> URL? {
        guard isDue else { return nil }
        var target = folder
        if isCustomFolder, !FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path) {
            target = defaultFolder
        }
        do {
            return try run(catalog: catalog, to: target)
        } catch {
            NSLog("LumaGrader: automatic catalog backup failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Restore

    static func scheduleRestore(from backup: URL) {
        UserDefaults.standard.set(backup.path, forKey: Keys.pendingRestore)
    }

    /// Swaps a scheduled backup in, before the catalog is opened. The current catalog (with
    /// its -wal/-shm files) is kept as "Catalog before restore.sqlite".
    static func applyPendingRestore(catalog: URL) throws {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: Keys.pendingRestore) else { return }
        defaults.removeObject(forKey: Keys.pendingRestore)

        let fm = FileManager.default
        let backup = URL(fileURLWithPath: path)
        guard fm.fileExists(atPath: backup.path) else {
            throw BackupError.sqlite("the backup to restore is gone (\(backup.lastPathComponent))")
        }
        try check(backup)

        let dir = catalog.deletingLastPathComponent()
        let saved = dir.appendingPathComponent("Catalog before restore.sqlite")
        for ext in ["", "-wal", "-shm"] {
            let current = URL(fileURLWithPath: catalog.path + ext)
            let keepAs = URL(fileURLWithPath: saved.path + ext)
            try? fm.removeItem(at: keepAs)
            if fm.fileExists(atPath: current.path) {
                try fm.moveItem(at: current, to: keepAs)
            }
        }
        do {
            try fm.copyItem(at: backup, to: catalog)
        } catch {
            // Put the old catalog back rather than starting an empty one.
            for ext in ["", "-wal", "-shm"] {
                let keepAs = URL(fileURLWithPath: saved.path + ext)
                if fm.fileExists(atPath: keepAs.path) {
                    try? fm.moveItem(at: keepAs, to: URL(fileURLWithPath: catalog.path + ext))
                }
            }
            throw error
        }
    }
}
