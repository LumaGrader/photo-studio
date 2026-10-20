import AppKit

/// Tethered capture through a hot folder: the camera's own tether app (Canon EOS Utility
/// for the R8) saves each shot into a folder, LumaGrader adds it to the catalog and shows it.
struct TetherState: Equatable {
    let folder: URL
    let folderID: Int64
    var shots = 0
    var lastFileName: String?
    var lastShotAt: Date?
    /// The latest shot (for Same as Previous).
    var lastPhotoID: Int64?
}

/// What each new tethered shot gets, like Lightroom's tether bar "Develop Settings".
enum TetherDevelop: Hashable {
    /// No settings (named `off`, not `none`, so it never mixes up with Optional.none).
    case off
    /// The settings of the shot before it (edit the first shot, the rest follow).
    case previous
    case preset(Int64)

    init(stored: String?) {
        switch stored {
        case "previous": self = .previous
        case let value? where value.hasPrefix("preset:"):
            if let id = Int64(value.dropFirst("preset:".count)) {
                self = .preset(id)
            } else {
                self = .off
            }
        default: self = .off
        }
    }

    var stored: String {
        switch self {
        case .off: return "none"
        case .previous: return "previous"
        case .preset(let id): return "preset:\(id)"
        }
    }

    /// Setting groups Same as Previous copies: everything except spots and masks, which belong
    /// to one frame (crop is copied, so a studio framing carries over).
    static let previousGroups: Set<SettingsGroup> =
        Set(SettingsGroup.allCases.filter { $0 != .spotRemoval && $0 != .masks })
}

extension LibraryStore {
    enum TetherDefaults {
        static let base = "tether.baseFolder"
        static let session = "tether.session"
    }

    /// ~/Pictures/LumaGrader Tether, or the folder chosen last time. If the folder from
    /// before the rename (~/Pictures/DarkLab Tether) exists, keep using it so EOS Utility's
    /// destination still matches.
    static var tetherBaseFolder: URL {
        if let path = UserDefaults.standard.string(forKey: TetherDefaults.base), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        let old = pictures.appendingPathComponent("LumaGrader Tether", isDirectory: true)
        if FileManager.default.fileExists(atPath: old.path) { return old }
        return pictures.appendingPathComponent("LumaGrader Tether", isDirectory: true)
    }

    /// `<base>/<yyyy-MM-dd> <Session>` (just `<base>/<yyyy-MM-dd>` without a name).
    static func tetherFolder(base: URL, session: String, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let name = session.trimmingCharacters(in: .whitespaces)
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let folderName = cleaned.isEmpty ? formatter.string(from: date) : "\(formatter.string(from: date)) \(cleaned)"
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    var isTethering: Bool { tether != nil }

    func beginTether() {
        showTetherSheet = true
    }

    /// Adds the folder to the catalog (with any photos already in it) and starts watching.
    @MainActor
    func startTether(folder: URL, base: URL, session: String) {
        stopTether()
        guard let catalog else { return }
        UserDefaults.standard.set(base.path, forKey: TetherDefaults.base)
        UserDefaults.standard.set(session, forKey: TetherDefaults.session)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Couldn't create the tether folder: \(error.localizedDescription)"
            return
        }

        Task { @MainActor in
            let existing = await Task.detached(priority: .userInitiated) {
                (try? FolderScanner.scan(folder)) ?? []
            }.value
            let folderID: Int64
            do {
                folderID = try catalog.addFolder(path: folder.path)
                try catalog.addPhotos(folderID: folderID, files: existing)
            } catch {
                errorMessage = "Couldn't start tethering: \(error.localizedDescription)"
                return
            }
            reloadFolders()
            if isFiltering { clearFilters() }
            if selectedFolderID == folderID { loadPhotos() } else { selectedFolderID = folderID }

            // Same as Previous starts from the newest photo already in the folder.
            let newestExisting = existing.max { $0.modified < $1.modified }?.url.path
            let lastID = newestExisting.flatMap { path in
                (try? catalog.photos(folderID: folderID))?.first { $0.url.path == path }?.id
            }
            tether = TetherState(folder: folder, folderID: folderID, lastPhotoID: lastID)
            let watcher = TetherWatcher(folder: folder, known: Set(existing.map(\.url.path))) { [weak self] files, turns in
                self?.receiveTethered(files, turns: turns)
            }
            tetherWatcher = watcher
            watcher.start()
        }
    }

    func stopTether() {
        tetherWatcher?.stop()
        tetherWatcher = nil
        tether = nil
    }

    /// New complete files from the hot folder.
    private func receiveTethered(_ files: [ScannedFile], turns: [String: AutoOrient.Turn]) {
        guard let catalog, var state = tether, !files.isEmpty else { return }
        do {
            try catalog.addPhotos(folderID: state.folderID, files: files)
        } catch {
            errorMessage = "Couldn't add the new shot: \(error.localizedDescription)"
            return
        }
        let newIDs = applyTetherDevelop(to: files, state: state)
        applyTetherTurns(turns, files: files, folderID: state.folderID)
        state.shots += files.count
        state.lastFileName = files.last?.url.lastPathComponent
        state.lastShotAt = Date()
        if let last = newIDs.last { state.lastPhotoID = last }
        tether = state

        // Only refresh what's on screen when the tether folder is the one shown.
        let showingTetherFolder = selectedFolderID == state.folderID && selectedCollectionID == nil
        guard showingTetherFolder || tetherShowNew else { return }

        let previousMode = viewMode
        if !showingTetherFolder {
            if isFiltering { clearFilters() }
            selectedFolderID = state.folderID // loads the photos
        } else {
            loadPhotos()
        }

        guard tetherShowNew else {
            // loadPhotos() goes back to the Grid; stay where you were.
            if [.grid, .loupe, .develop, .print].contains(previousMode), selectedPhotoID != nil || previousMode == .grid {
                setViewMode(previousMode)
            }
            return
        }
        // Newest shot that is visible (a JPEG twin may be hidden behind its RAW).
        let newPaths = Set(files.map(\.url.path))
        let visible = visiblePhotos
        guard let newest = visible.last(where: { newPaths.contains($0.url.path) })
                ?? visible.first(where: { newPaths.contains($0.url.path) })
        else { return }
        select(newest.id)
        setViewMode(previousMode == .develop ? .develop : .loupe)
    }

    /// Gives the new shots their develop settings (None / Same as Previous / preset) straight in
    /// the catalog, before they're shown. Returns their ids, oldest first.
    private func applyTetherDevelop(to files: [ScannedFile], state: TetherState) -> [Int64] {
        guard let catalog, let folderPhotos = try? catalog.photos(folderID: state.folderID) else { return [] }
        let order = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1.url.path, $0) })
        let newPhotos = folderPhotos
            .filter { order[$0.url.path] != nil && !$0.isVirtualCopy }
            .sorted { order[$0.url.path]! < order[$1.url.path]! }

        let source: (settings: DevelopSettings, groups: (Photo) -> Set<SettingsGroup>)?
        switch tetherDevelop {
        case .off:
            source = nil
        case .previous:
            develop.flushSave()
            if let previousID = state.lastPhotoID,
               let settings = currentSettings(of: previousID)
                ?? folderPhotos.first(where: { $0.id == previousID })?.develop {
                source = (settings, { _ in TetherDevelop.previousGroups })
            } else {
                source = nil
            }
        case .preset(let id):
            if let preset = presets.first(where: { $0.id == id }) {
                source = (preset.settings, { photo in Self.groups(preset.groups, from: preset.settings, for: photo) })
            } else {
                source = nil
            }
        }

        if let source {
            for photo in newPhotos {
                let settings = photo.develop.merging(source.settings, groups: source.groups(photo))
                guard settings != photo.develop else { continue }
                do {
                    try catalog.setDevelop(settings, photoID: photo.id)
                    updatePhotos([photo.id]) { $0.develop = settings }
                } catch {
                    errorMessage = "Couldn't apply settings to \(photo.fileName): \(error.localizedDescription)"
                    break
                }
            }
        }
        // RAW over its JPEG twin, so "previous" is the photo you see.
        let raws = newPhotos.filter(\.isRaw)
        return (raws.isEmpty ? newPhotos : raws).map(\.id)
    }

    /// Auto-Rotate Portraits for new shots (turns worked out by the watcher). After the develop
    /// settings, so Same as Previous with its own quarter turn wins.
    private func applyTetherTurns(_ turns: [String: AutoOrient.Turn], files: [ScannedFile], folderID: Int64) {
        guard let catalog, let folderPhotos = try? catalog.photos(folderID: folderID) else { return }
        let paths = Set(files.map(\.url.path))
        let newPhotos = folderPhotos.filter { paths.contains($0.url.path) && !$0.isVirtualCopy }
        for photo in newPhotos {
            if let turn = turns[photo.url.path] { applyTurn(turn, to: photo.id) }
        }
        try? catalog.markOrientChecked(newPhotos.map(\.id))
    }

    /// Label for the tether Develop Settings menus.
    func tetherDevelopTitle(_ choice: TetherDevelop) -> String {
        switch choice {
        case .off: return "None"
        case .previous: return "Same as Previous"
        case .preset(let id): return presets.first { $0.id == id }?.name ?? "Missing preset"
        }
    }

    /// EOS Utility (or another Canon Utilities app) if it's installed.
    static func eosUtilityURL() -> URL? {
        let roots = ["/Applications/Canon Utilities", "/Applications"]
        let fm = FileManager.default
        for root in roots {
            guard let items = fm.enumerator(at: URL(fileURLWithPath: root),
                                            includingPropertiesForKeys: nil,
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in items {
                if url.pathExtension == "app", url.lastPathComponent.hasPrefix("EOS Utility") {
                    return url
                }
                // /Applications itself: don't walk into every app folder.
                if root == "/Applications", items.level > 2 { items.skipDescendants() }
            }
        }
        return nil
    }
}
