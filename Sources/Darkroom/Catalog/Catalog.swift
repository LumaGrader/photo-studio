import Foundation
import SQLite3

enum CatalogError: LocalizedError {
    case open(String)
    case sql(String)

    var errorDescription: String? {
        switch self {
        case .open(let message): return "Can't open the catalog: \(message)"
        case .sql(let message): return "Catalog error: \(message)"
        }
    }
}

/// SQLite's "copy this string now" marker (not imported into Swift as a constant).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The photo catalog: folders, photos, ratings and flags in one SQLite file.
/// Photos are referenced in place — the catalog never moves or changes your files.
/// Use from the main thread only.
final class Catalog {
    enum Value {
        case int(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
        case null
    }

    private var db: OpaquePointer?

    static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Darkroom", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Catalog.sqlite")
    }

    init(url: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(url.path, &db, flags, nil) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            db = nil
            throw CatalogError.open(message)
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Schema

    private func migrate() throws {
        let version = try query("PRAGMA user_version;") { Int(sqlite3_column_int($0, 0)) }.first ?? 0
        if version < 1 {
            try transaction {
                try exec("""
                CREATE TABLE folders (
                  id INTEGER PRIMARY KEY,
                  path TEXT NOT NULL UNIQUE,
                  added_at REAL NOT NULL
                );
                CREATE TABLE photos (
                  id INTEGER PRIMARY KEY,
                  folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
                  path TEXT NOT NULL UNIQUE,
                  file_name TEXT NOT NULL,
                  file_size INTEGER NOT NULL DEFAULT 0,
                  modified_at REAL NOT NULL DEFAULT 0,
                  rating INTEGER NOT NULL DEFAULT 0 CHECK (rating BETWEEN 0 AND 5),
                  flag INTEGER NOT NULL DEFAULT 0 CHECK (flag IN (-1, 0, 1)),
                  added_at REAL NOT NULL
                );
                CREATE INDEX photos_by_folder ON photos(folder_id, file_name);
                PRAGMA user_version = 1;
                """)
            }
        }
        if version < 2 {
            try transaction {
                try exec("""
                ALTER TABLE photos ADD COLUMN develop TEXT;
                PRAGMA user_version = 2;
                """)
            }
        }
        if version < 3 {
            try transaction {
                try exec("""
                CREATE TABLE presets (
                  id INTEGER PRIMARY KEY,
                  name TEXT NOT NULL UNIQUE,
                  settings TEXT NOT NULL,
                  group_list TEXT NOT NULL,
                  created_at REAL NOT NULL
                );
                PRAGMA user_version = 3;
                """)
            }
        }
        if version < 4 {
            try transaction {
                try exec("""
                ALTER TABLE photos ADD COLUMN meta TEXT;
                CREATE TABLE analysis (
                  photo_id INTEGER PRIMARY KEY REFERENCES photos(id) ON DELETE CASCADE,
                  aesthetic REAL,
                  utility INTEGER NOT NULL DEFAULT 0,
                  sharpness REAL NOT NULL DEFAULT 0,
                  faces INTEGER NOT NULL DEFAULT 0,
                  eyes_closed INTEGER NOT NULL DEFAULT 0,
                  dist_prev REAL,
                  analyzed_at REAL NOT NULL
                );
                PRAGMA user_version = 4;
                """)
            }
        }
        if version < 5 {
            // Virtual copies share a file, so `path` alone can't be unique any more: rebuild the
            // photos table (same ids) with UNIQUE(path, copy_index). Foreign keys must be off
            // while the table is swapped (they can't be switched inside a transaction).
            try exec("PRAGMA foreign_keys=OFF;")
            defer { try? exec("PRAGMA foreign_keys=ON;") }
            try transaction {
                try exec("""
                CREATE TABLE photos_new (
                  id INTEGER PRIMARY KEY,
                  folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
                  path TEXT NOT NULL,
                  copy_index INTEGER NOT NULL DEFAULT 0,
                  file_name TEXT NOT NULL,
                  file_size INTEGER NOT NULL DEFAULT 0,
                  modified_at REAL NOT NULL DEFAULT 0,
                  rating INTEGER NOT NULL DEFAULT 0 CHECK (rating BETWEEN 0 AND 5),
                  flag INTEGER NOT NULL DEFAULT 0 CHECK (flag IN (-1, 0, 1)),
                  added_at REAL NOT NULL,
                  develop TEXT,
                  meta TEXT,
                  UNIQUE (path, copy_index)
                );
                INSERT INTO photos_new (id, folder_id, path, copy_index, file_name, file_size, modified_at,
                                        rating, flag, added_at, develop, meta)
                  SELECT id, folder_id, path, 0, file_name, file_size, modified_at, rating, flag, added_at, develop, meta
                  FROM photos;
                DROP TABLE photos;
                ALTER TABLE photos_new RENAME TO photos;
                CREATE INDEX photos_by_folder ON photos(folder_id, file_name);
                CREATE TABLE collections (
                  id INTEGER PRIMARY KEY,
                  name TEXT NOT NULL UNIQUE,
                  created_at REAL NOT NULL
                );
                CREATE TABLE collection_photos (
                  collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
                  photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
                  added_at REAL NOT NULL,
                  PRIMARY KEY (collection_id, photo_id)
                );
                CREATE TABLE snapshots (
                  id INTEGER PRIMARY KEY,
                  photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
                  name TEXT NOT NULL,
                  settings TEXT NOT NULL,
                  created_at REAL NOT NULL
                );
                CREATE INDEX snapshots_by_photo ON snapshots(photo_id);
                PRAGMA user_version = 5;
                """)
            }
        }
        if version < 6 {
            // Colour labels (0 = none … 5 = purple).
            try transaction {
                try exec("""
                ALTER TABLE photos ADD COLUMN label INTEGER NOT NULL DEFAULT 0;
                PRAGMA user_version = 6;
                """)
            }
        }
        if version < 7 {
            // People (face tagging). Faces are stored in the upright, uncropped photo,
            // 0…1 from the top-left; `print` is an archived Vision feature print.
            try transaction {
                try exec("""
                CREATE TABLE people (
                  id INTEGER PRIMARY KEY,
                  name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                  created_at REAL NOT NULL
                );
                CREATE TABLE faces (
                  id INTEGER PRIMARY KEY,
                  photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
                  x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL,
                  print BLOB,
                  thumb BLOB,
                  person_id INTEGER REFERENCES people(id) ON DELETE SET NULL,
                  ignored INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX faces_by_photo ON faces(photo_id);
                CREATE INDEX faces_by_person ON faces(person_id);
                CREATE TABLE face_scans (
                  photo_id INTEGER PRIMARY KEY REFERENCES photos(id) ON DELETE CASCADE,
                  scanned_at REAL NOT NULL
                );
                PRAGMA user_version = 7;
                """)
            }
        }
        if version < 8 {
            // Files already copied from a card (name|size|date), so a re-import skips them.
            try transaction {
                try exec("""
                CREATE TABLE import_history (
                  signature TEXT PRIMARY KEY,
                  imported_at REAL NOT NULL
                );
                PRAGMA user_version = 8;
                """)
            }
        }
        if version < 9 {
            // Photos already checked by Auto-Rotate Portraits (so a resync doesn't redo them).
            try transaction {
                try exec("""
                CREATE TABLE orient_checks (
                  photo_id INTEGER PRIMARY KEY REFERENCES photos(id) ON DELETE CASCADE
                );
                PRAGMA user_version = 9;
                """)
            }
        }
    }

    // MARK: - Presets

    func presets() throws -> [DevelopPreset] {
        try query("SELECT id, name, settings, group_list FROM presets ORDER BY name COLLATE NOCASE;") { row -> DevelopPreset in
            let groups = (Self.text(row, 3) ?? "")
                .split(separator: ",")
                .compactMap { SettingsGroup(rawValue: String($0)) }
            return DevelopPreset(
                id: sqlite3_column_int64(row, 0),
                name: Self.text(row, 1) ?? "Preset",
                settings: DevelopSettings.from(json: Self.text(row, 2)),
                groups: Set(groups))
        }
    }

    /// Saves (or replaces, by name) a preset.
    func savePreset(name: String, settings: DevelopSettings, groups: Set<SettingsGroup>) throws {
        let data = try JSONEncoder().encode(settings)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let groupList = SettingsGroup.allCases.filter(groups.contains).map(\.rawValue).joined(separator: ",")
        try run("""
        INSERT INTO presets (name, settings, group_list, created_at) VALUES (?, ?, ?, ?)
        ON CONFLICT(name) DO UPDATE SET settings = excluded.settings, group_list = excluded.group_list;
        """, [.text(name), .text(json), .text(groupList), .double(Date().timeIntervalSince1970)])
    }

    func deletePreset(id: Int64) throws {
        try run("DELETE FROM presets WHERE id = ?;", [.int(id)])
    }

    // MARK: - Folders

    func folders() throws -> [Folder] {
        try query("SELECT id, path FROM folders ORDER BY path COLLATE NOCASE;") { row in
            Folder(id: sqlite3_column_int64(row, 0),
                   url: URL(fileURLWithPath: Self.text(row, 1) ?? "", isDirectory: true))
        }
    }

    /// Adds the folder if it's new; returns its id either way.
    func addFolder(path: String) throws -> Int64 {
        try run("INSERT OR IGNORE INTO folders (path, added_at) VALUES (?, ?);",
                [.text(path), .double(Date().timeIntervalSince1970)])
        let ids = try query("SELECT id FROM folders WHERE path = ?;", [.text(path)]) {
            sqlite3_column_int64($0, 0)
        }
        guard let id = ids.first else { throw CatalogError.sql("Folder was not saved.") }
        return id
    }

    /// Photos in a folder (virtual copies not counted).
    func photoCount(folderID: Int64) throws -> Int {
        try query("SELECT COUNT(*) FROM photos WHERE folder_id = ? AND copy_index = 0;", [.int(folderID)]) {
            Int(sqlite3_column_int64($0, 0))
        }.first ?? 0
    }

    /// Removes a folder from the catalog with all its photos (their edits, snapshots, faces and
    /// collection entries go with them). Files on disk are not touched here.
    func removeFolder(id: Int64) throws {
        try run("DELETE FROM folders WHERE id = ?;", [.int(id)])
    }

    // MARK: - Photos

    /// Adds files not yet in the catalog. Existing photos keep their ratings and flags.
    /// Returns how many photos were new.
    @discardableResult
    func addPhotos(folderID: Int64, files: [ScannedFile]) throws -> Int {
        var added = 0
        try transaction {
            let stmt = try prepare("""
            INSERT OR IGNORE INTO photos (folder_id, path, file_name, file_size, modified_at, added_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """)
            let now = Date().timeIntervalSince1970
            for file in files {
                sqlite3_reset(stmt.handle)
                sqlite3_clear_bindings(stmt.handle)
                try bind(stmt, [
                    .int(folderID),
                    .text(file.url.path),
                    .text(file.url.lastPathComponent),
                    .int(file.size),
                    .double(file.modified.timeIntervalSince1970),
                    .double(now),
                ])
                guard sqlite3_step(stmt.handle) == SQLITE_DONE else { throw CatalogError.sql(lastError) }
                added += Int(sqlite3_changes(db))
            }
        }
        return added
    }

    private static let photoColumns = "p.id, p.folder_id, p.path, p.file_name, p.rating, p.flag, p.develop, p.meta, p.copy_index, p.label"

    private static func photo(_ row: OpaquePointer) -> Photo {
        Photo(id: sqlite3_column_int64(row, 0),
              folderID: sqlite3_column_int64(row, 1),
              url: URL(fileURLWithPath: text(row, 2) ?? ""),
              fileName: text(row, 3) ?? "",
              rating: Int(sqlite3_column_int(row, 4)),
              flag: Flag(rawValue: Int(sqlite3_column_int(row, 5))) ?? .unflagged,
              label: ColorLabel(rawValue: Int(sqlite3_column_int(row, 9))) ?? .none,
              develop: DevelopSettings.from(json: text(row, 6)),
              meta: PhotoMeta.from(json: text(row, 7)),
              copyIndex: Int(sqlite3_column_int(row, 8)))
    }

    func photos(folderID: Int64) throws -> [Photo] {
        try query("""
        SELECT \(Self.photoColumns) FROM photos p WHERE p.folder_id = ?
        ORDER BY p.file_name COLLATE NOCASE, p.path, p.copy_index;
        """, [.int(folderID)], row: Self.photo)
    }

    func photos(collectionID: Int64) throws -> [Photo] {
        try query("""
        SELECT \(Self.photoColumns) FROM photos p
        JOIN collection_photos c ON c.photo_id = p.id WHERE c.collection_id = ?
        ORDER BY p.file_name COLLATE NOCASE, p.path, p.copy_index;
        """, [.int(collectionID)], row: Self.photo)
    }

    // MARK: - Virtual copies

    /// A new catalog entry for the same file with its own settings. Returns its id.
    func createVirtualCopy(of photo: Photo) throws -> Int64 {
        let next = try query("SELECT COALESCE(MAX(copy_index), 0) + 1 FROM photos WHERE path = ?;",
                             [.text(photo.url.path)]) { sqlite3_column_int64($0, 0) }.first ?? 1
        try run("""
        INSERT INTO photos (folder_id, path, copy_index, file_name, file_size, modified_at, added_at, develop, meta)
        SELECT folder_id, path, ?, file_name, file_size, modified_at, ?, develop, meta FROM photos WHERE id = ?;
        """, [.int(next), .double(Date().timeIntervalSince1970), .int(photo.id)])
        return sqlite3_last_insert_rowid(db)
    }

    /// Only virtual copies can be removed (the file stays untouched either way).
    func deleteVirtualCopy(id: Int64) throws {
        try run("DELETE FROM photos WHERE id = ? AND copy_index > 0;", [.int(id)])
    }

    /// Removes photos from the catalog (their edits, snapshots, faces and collection entries go
    /// with them). Removing a photo also removes its virtual copies, which share its file.
    /// Files on disk are not touched here.
    func removePhotos(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try transaction {
            for id in ids {
                try run("""
                DELETE FROM photos WHERE id = ?
                   OR (path = (SELECT path FROM photos WHERE id = ? AND copy_index = 0));
                """, [.int(id), .int(id)])
            }
        }
    }

    // MARK: - Collections

    func collections() throws -> [PhotoCollection] {
        try query("""
        SELECT c.id, c.name, COUNT(cp.photo_id) FROM collections c
        LEFT JOIN collection_photos cp ON cp.collection_id = c.id
        GROUP BY c.id ORDER BY c.name COLLATE NOCASE;
        """) { row in
            PhotoCollection(id: sqlite3_column_int64(row, 0), name: Self.text(row, 1) ?? "",
                            count: Int(sqlite3_column_int(row, 2)))
        }
    }

    func createCollection(name: String) throws -> Int64 {
        try run("INSERT INTO collections (name, created_at) VALUES (?, ?);",
                [.text(name), .double(Date().timeIntervalSince1970)])
        return sqlite3_last_insert_rowid(db)
    }

    func renameCollection(id: Int64, name: String) throws {
        try run("UPDATE collections SET name = ? WHERE id = ?;", [.text(name), .int(id)])
    }

    func deleteCollection(id: Int64) throws {
        try run("DELETE FROM collections WHERE id = ?;", [.int(id)])
    }

    func addToCollection(_ collectionID: Int64, photoIDs: [Int64]) throws {
        try transaction {
            for id in photoIDs {
                try run("INSERT OR IGNORE INTO collection_photos (collection_id, photo_id, added_at) VALUES (?, ?, ?);",
                        [.int(collectionID), .int(id), .double(Date().timeIntervalSince1970)])
            }
        }
    }

    func removeFromCollection(_ collectionID: Int64, photoIDs: [Int64]) throws {
        try transaction {
            for id in photoIDs {
                try run("DELETE FROM collection_photos WHERE collection_id = ? AND photo_id = ?;",
                        [.int(collectionID), .int(id)])
            }
        }
    }

    // MARK: - Snapshots

    func snapshots(photoID: Int64) throws -> [Snapshot] {
        try query("SELECT id, name, settings FROM snapshots WHERE photo_id = ? ORDER BY created_at DESC, id DESC;",
                  [.int(photoID)]) { row in
            Snapshot(id: sqlite3_column_int64(row, 0), name: Self.text(row, 1) ?? "",
                     settings: DevelopSettings.from(json: Self.text(row, 2)))
        }
    }

    func addSnapshot(photoID: Int64, name: String, settings: DevelopSettings) throws {
        let data = try JSONEncoder().encode(settings)
        try run("INSERT INTO snapshots (photo_id, name, settings, created_at) VALUES (?, ?, ?, ?);",
                [.int(photoID), .text(name), .text(String(data: data, encoding: .utf8) ?? "{}"),
                 .double(Date().timeIntervalSince1970)])
    }

    func deleteSnapshot(id: Int64) throws {
        try run("DELETE FROM snapshots WHERE id = ?;", [.int(id)])
    }

    func setMeta(_ meta: PhotoMeta, photoID: Int64) throws {
        let value: Value = meta.jsonString().map { .text($0) } ?? .null
        try run("UPDATE photos SET meta = ? WHERE id = ?;", [value, .int(photoID)])
    }

    // MARK: - AI analysis

    func analysis(folderID: Int64) throws -> [Int64: PhotoAnalysis] {
        try analysis(where: "JOIN photos p ON p.id = a.photo_id WHERE p.folder_id = ?", folderID)
    }

    func analysis(collectionID: Int64) throws -> [Int64: PhotoAnalysis] {
        try analysis(where: "JOIN collection_photos c ON c.photo_id = a.photo_id WHERE c.collection_id = ?", collectionID)
    }

    private func analysis(where clause: String, _ id: Int64) throws -> [Int64: PhotoAnalysis] {
        let rows = try query("""
        SELECT a.photo_id, a.aesthetic, a.utility, a.sharpness, a.faces, a.eyes_closed, a.dist_prev
        FROM analysis a \(clause);
        """, [.int(id)]) { row -> (Int64, PhotoAnalysis) in
            let aesthetic: Double? = sqlite3_column_type(row, 1) == SQLITE_NULL ? nil : sqlite3_column_double(row, 1)
            let distance: Double? = sqlite3_column_type(row, 6) == SQLITE_NULL ? nil : sqlite3_column_double(row, 6)
            return (sqlite3_column_int64(row, 0), PhotoAnalysis(
                aesthetic: aesthetic,
                utility: sqlite3_column_int(row, 2) != 0,
                sharpness: sqlite3_column_double(row, 3),
                faces: Int(sqlite3_column_int(row, 4)),
                eyesClosed: Int(sqlite3_column_int(row, 5)),
                distanceToPrevious: distance))
        }
        return Dictionary(rows, uniquingKeysWith: { a, _ in a })
    }

    func saveAnalysis(_ a: PhotoAnalysis, photoID: Int64) throws {
        try run("""
        INSERT OR REPLACE INTO analysis (photo_id, aesthetic, utility, sharpness, faces, eyes_closed, dist_prev, analyzed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .int(photoID),
            a.aesthetic.map { Value.double($0) } ?? .null,
            .int(a.utility ? 1 : 0),
            .double(a.sharpness),
            .int(Int64(a.faces)),
            .int(Int64(a.eyesClosed)),
            a.distanceToPrevious.map { Value.double($0) } ?? .null,
            .double(Date().timeIntervalSince1970),
        ])
    }

    func setRating(_ rating: Int, photoIDs: [Int64]) throws {
        let clamped = Int64(min(max(rating, 0), 5))
        try transaction {
            for id in photoIDs {
                try run("UPDATE photos SET rating = ? WHERE id = ?;", [.int(clamped), .int(id)])
            }
        }
    }

    // MARK: - Import history

    func importedSignatures() throws -> Set<String> {
        Set(try query("SELECT signature FROM import_history;") { Self.text($0, 0) ?? "" })
    }

    func recordImported(_ signatures: [String]) throws {
        let now = Date().timeIntervalSince1970
        try transaction {
            for signature in signatures {
                try run("INSERT OR REPLACE INTO import_history (signature, imported_at) VALUES (?, ?);",
                        [.text(signature), .double(now)])
            }
        }
    }

    // MARK: - People

    /// Photo ids already searched for faces.
    // MARK: - Auto-Rotate Portraits

    func orientCheckedPhotoIDs() throws -> Set<Int64> {
        Set(try query("SELECT photo_id FROM orient_checks;") { sqlite3_column_int64($0, 0) })
    }

    func markOrientChecked(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try transaction {
            for id in ids {
                try run("INSERT OR IGNORE INTO orient_checks (photo_id) VALUES (?);", [.int(id)])
            }
        }
    }

    func faceScannedPhotoIDs() throws -> Set<Int64> {
        Set(try query("SELECT photo_id FROM face_scans;") { sqlite3_column_int64($0, 0) })
    }

    /// Saves the faces found in one photo and marks it as searched.
    func saveFaces(_ faces: [DetectedFace], photoID: Int64) throws {
        try transaction {
            for face in faces {
                try run("""
                INSERT INTO faces (photo_id, x, y, w, h, print, thumb) VALUES (?, ?, ?, ?, ?, ?, ?);
                """, [
                    .int(photoID),
                    .double(Double(face.rect.minX)), .double(Double(face.rect.minY)),
                    .double(Double(face.rect.width)), .double(Double(face.rect.height)),
                    face.print.map { Value.blob($0) } ?? .null,
                    face.thumb.map { Value.blob($0) } ?? .null,
                ])
            }
            try run("INSERT OR REPLACE INTO face_scans (photo_id, scanned_at) VALUES (?, ?);",
                    [.int(photoID), .double(Date().timeIntervalSince1970)])
        }
    }

    func people() throws -> [Person] {
        try query("""
        SELECT p.id, p.name, COUNT(f.id) FROM people p
        LEFT JOIN faces f ON f.person_id = p.id AND f.ignored = 0
        GROUP BY p.id ORDER BY p.name COLLATE NOCASE;
        """) { row in
            Person(id: sqlite3_column_int64(row, 0), name: Self.text(row, 1) ?? "",
                   faceCount: Int(sqlite3_column_int(row, 2)))
        }
    }

    /// Every face that isn't ignored, with its photo's path.
    func faces() throws -> [FaceRecord] {
        try query("""
        SELECT f.id, f.photo_id, f.x, f.y, f.w, f.h, f.print, f.thumb, f.person_id, ph.path
        FROM faces f JOIN photos ph ON ph.id = f.photo_id
        WHERE f.ignored = 0 ORDER BY f.id;
        """) { row in
            FaceRecord(id: sqlite3_column_int64(row, 0),
                       photoID: sqlite3_column_int64(row, 1),
                       rect: CGRect(x: sqlite3_column_double(row, 2), y: sqlite3_column_double(row, 3),
                                    width: sqlite3_column_double(row, 4), height: sqlite3_column_double(row, 5)),
                       print: Self.blob(row, 6),
                       thumb: Self.blob(row, 7),
                       personID: sqlite3_column_type(row, 8) == SQLITE_NULL ? nil : sqlite3_column_int64(row, 8),
                       path: Self.text(row, 9) ?? "")
        }
    }

    /// The person with this name (created if new). Returns its id.
    func person(named name: String) throws -> Int64 {
        try run("INSERT OR IGNORE INTO people (name, created_at) VALUES (?, ?);",
                [.text(name), .double(Date().timeIntervalSince1970)])
        guard let id = try query("SELECT id FROM people WHERE name = ? COLLATE NOCASE;", [.text(name)], row: {
            sqlite3_column_int64($0, 0)
        }).first else { throw CatalogError.sql("Person was not saved.") }
        return id
    }

    /// nil = unnamed again.
    func assignFaces(_ faceIDs: [Int64], to personID: Int64?) throws {
        try transaction {
            for id in faceIDs {
                try run("UPDATE faces SET person_id = ? WHERE id = ?;",
                        [personID.map { Value.int($0) } ?? .null, .int(id)])
            }
        }
    }

    /// "Not a face" / don't ask again.
    func ignoreFaces(_ faceIDs: [Int64]) throws {
        try transaction {
            for id in faceIDs {
                try run("UPDATE faces SET ignored = 1, person_id = NULL WHERE id = ?;", [.int(id)])
            }
        }
    }

    func renamePerson(_ id: Int64, to name: String) throws {
        try run("UPDATE people SET name = ? WHERE id = ?;", [.text(name), .int(id)])
    }

    /// Faces of a deleted person become unnamed.
    func deletePerson(_ id: Int64) throws {
        try run("DELETE FROM people WHERE id = ?;", [.int(id)])
    }

    /// Files (paths) that show this person, so virtual copies match too.
    func photoPaths(personID: Int64) throws -> Set<String> {
        Set(try query("""
        SELECT DISTINCT ph.path FROM faces f JOIN photos ph ON ph.id = f.photo_id
        WHERE f.person_id = ? AND f.ignored = 0;
        """, [.int(personID)]) { Self.text($0, 0) ?? "" })
    }

    /// Names of the people in a file.
    func peopleNames(path: String) throws -> [String] {
        try query("""
        SELECT DISTINCT p.name FROM faces f
        JOIN people p ON p.id = f.person_id JOIN photos ph ON ph.id = f.photo_id
        WHERE ph.path = ? AND f.ignored = 0 ORDER BY p.name COLLATE NOCASE;
        """, [.text(path)]) { Self.text($0, 0) ?? "" }
    }

    func setLabel(_ label: ColorLabel, photoIDs: [Int64]) throws {
        try transaction {
            for id in photoIDs {
                try run("UPDATE photos SET label = ? WHERE id = ?;", [.int(Int64(label.rawValue)), .int(id)])
            }
        }
    }

    func setFlag(_ flag: Flag, photoIDs: [Int64]) throws {
        try transaction {
            for id in photoIDs {
                try run("UPDATE photos SET flag = ? WHERE id = ?;", [.int(Int64(flag.rawValue)), .int(id)])
            }
        }
    }

    /// Default settings are stored as NULL.
    func setDevelop(_ settings: DevelopSettings, photoID: Int64) throws {
        let value: Value = settings.jsonString().map { .text($0) } ?? .null
        try run("UPDATE photos SET develop = ? WHERE id = ?;", [value, .int(photoID)])
    }

    // MARK: - SQLite helpers

    private final class Statement {
        let handle: OpaquePointer
        init(_ handle: OpaquePointer) { self.handle = handle }
        deinit { sqlite3_finalize(handle) }
    }

    private var lastError: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
    }

    private static func blob(_ row: OpaquePointer, _ column: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(row, column))
        guard count > 0, let pointer = sqlite3_column_blob(row, column) else { return nil }
        return Data(bytes: pointer, count: count)
    }

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(row, column) else { return nil }
        return String(cString: pointer)
    }

    private func exec(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? lastError
            sqlite3_free(errorPointer)
            throw CatalogError.sql(message)
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN;")
        do {
            try body()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> Statement {
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK, let handle else {
            throw CatalogError.sql(lastError)
        }
        return Statement(handle)
    }

    private func bind(_ stmt: Statement, _ values: [Value]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .int(let v): result = sqlite3_bind_int64(stmt.handle, index, v)
            case .double(let v): result = sqlite3_bind_double(stmt.handle, index, v)
            case .text(let v): result = sqlite3_bind_text(stmt.handle, index, v, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                result = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(stmt.handle, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                }
            case .null: result = sqlite3_bind_null(stmt.handle, index)
            }
            guard result == SQLITE_OK else { throw CatalogError.sql(lastError) }
        }
    }

    private func run(_ sql: String, _ values: [Value] = []) throws {
        let stmt = try prepare(sql)
        try bind(stmt, values)
        let result = sqlite3_step(stmt.handle)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw CatalogError.sql(lastError) }
    }

    private func query<T>(_ sql: String, _ values: [Value] = [], row: (OpaquePointer) -> T) throws -> [T] {
        let stmt = try prepare(sql)
        try bind(stmt, values)
        var rows: [T] = []
        while true {
            let result = sqlite3_step(stmt.handle)
            if result == SQLITE_ROW {
                rows.append(row(stmt.handle))
            } else if result == SQLITE_DONE {
                break
            } else {
                throw CatalogError.sql(lastError)
            }
        }
        return rows
    }
}
