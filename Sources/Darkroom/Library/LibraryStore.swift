import Foundation
import AppKit
import UniformTypeIdentifiers
import Vision

enum KeyCommand {
    case previous, next, escape, enter, space
    case rating(Int)
    case label(ColorLabel)
    case pick, reject, unflag
    case grid, loupe, compare, develop
    case beforeAfter
    case selectAll
    case crop, zoom
    case togglePanels, toggleAllPanels, fullScreen
    case whiteBalancePicker, blackWhite, clipping
    case masking, newMask(MaskKind), maskOverlay
    case compareLayout
    case healing, delete, smaller, larger
    case survey
    case focusPeaking, zoomToFocus
}

/// Which "choose setting groups" sheet is open.
enum SettingsSheet: String, Identifiable {
    case copy, savePreset, sync
    var id: String { rawValue }
}

/// App state for the Library: folders, photos, selection, filters.
/// Mutated on the main thread only (UI actions, key monitor, @MainActor async work).
final class LibraryStore: ObservableObject {
    enum ViewMode: Hashable {
        case grid, loupe, compare, survey, develop, print
    }

    enum FlagFilter: String, CaseIterable, Identifiable {
        case all = "All photos"
        case picks = "Picks"
        case unflagged = "Unflagged"
        case rejected = "Rejected"

        var id: String { rawValue }
    }

    /// Library Filter by colour label.
    enum LabelFilter: Hashable, Identifiable {
        case any
        case only(ColorLabel)
        /// Photos with no label.
        case unlabeled

        var id: String {
            switch self {
            case .any: return "any"
            case .only(let label): return "label-\(label.rawValue)"
            case .unlabeled: return "none"
            }
        }

        var title: String {
            switch self {
            case .any: return "Any label"
            case .only(let label): return label.name
            case .unlabeled: return "No label"
            }
        }

        static var allOptions: [LabelFilter] { [.any] + ColorLabel.colors.map { .only($0) } + [.unlabeled] }
    }

    @Published private(set) var folders: [Folder] = []
    @Published var selectedFolderID: Int64? {
        didSet {
            guard oldValue != selectedFolderID else { return }
            if selectedFolderID != nil { selectedCollectionID = nil }
            loadPhotos()
        }
    }
    /// A collection shown instead of a folder (Collections panel).
    @Published private(set) var selectedCollectionID: Int64?
    @Published private(set) var collections: [PhotoCollection] = []
    /// Snapshots of the photo open in Develop.
    @Published private(set) var snapshots: [Snapshot] = []
    @Published private(set) var photos: [Photo] = []
    /// The active photo (shown in Loupe/Develop, the "Candidate" in Compare).
    @Published private(set) var selectedPhotoID: Int64? {
        didSet {
            if let old = oldValue, old != selectedPhotoID { previousPhotoID = old }
        }
    }
    /// The photo that was active before the current one (Paste from Previous).
    private(set) var previousPhotoID: Int64?
    /// All selected photos in the grid (always includes the active one).
    @Published private(set) var selectedIDs: Set<Int64> = []
    /// Left photo ("Select") in Compare.
    @Published private(set) var compareLeftID: Int64?
    @Published private(set) var viewMode: ViewMode = .grid
    @Published var flagFilter: FlagFilter = .all
    @Published var minRating = 0
    @Published var labelFilter: LabelFilter = .any
    /// People: show only photos of this person (nil = anyone).
    @Published var personFilter: Int64? {
        didSet { if oldValue != personFilter { reloadPersonPaths() } }
    }
    /// Files that show `personFilter`.
    @Published var personPaths: Set<String> = []
    @Published var people: [Person] = []
    @Published var faceProgress: BatchProgress?
    @Published var showPeopleSheet = false
    @Published var showCommandPalette = false
    @Published var showImportSheet = false
    /// Copying from a card (top bar shows it).
    @Published var importProgress: BatchProgress?
    /// Short note in the top bar after a backup ("Catalog backed up").
    @Published var backupStatus: String?
    @Published var isBackingUp = false
    @Published var autoBackup = CatalogBackup.autoEnabled {
        didSet { CatalogBackup.autoEnabled = autoBackup }
    }
    var importTask: Task<Void, Never>?
    var importCancel: CancelFlag?
    /// Auto Sync: with several photos selected, edits to the active photo go to all of them.
    @Published var autoSync = UserDefaults.standard.bool(forKey: "ui.autoSync") {
        didSet { UserDefaults.standard.set(autoSync, forKey: "ui.autoSync") }
    }
    /// Bumped whenever faces or people change (the People window reloads).
    @Published var facesVersion = 0
    var faceTask: Task<Void, Never>?
    /// Library Filter text: file name, title, caption, creator, keywords.
    @Published var searchText = ""
    /// Sort the grid by AI Cull score (best first) instead of file name.
    @Published var sortByScore = false
    /// AI Cull results for the current folder.
    @Published private(set) var analysis: [Int64: PhotoAnalysis] = [:]
    @Published private(set) var cullProgress: (done: Int, total: Int)?
    @Published var showCullSheet = false
    private var cullTask: Task<Void, Never>?
    @Published var autoAdvance = false
    @Published var stackRawJpeg = true {
        didSet { rebuildStacks() }
    }
    @Published private(set) var isImporting = false
    /// Photos waiting in the Export sheet (nil = sheet closed).
    @Published var exportPhotos: [Photo]?
    /// Loupe/Develop zoom (stays while stepping through photos, like Lightroom).
    @Published var zoom: ZoomLevel = .fit
    /// What Z and a click at Fit zoom to: the last level picked from the zoom menu.
    @Published private(set) var lastZoom: ZoomLevel = {
        let saved = UserDefaults.standard.double(forKey: "ui.lastZoom")
        return .percent(saved > 0 ? saved : 100)
    }()

    func pickZoom(_ level: ZoomLevel) {
        if case .percent(let p) = level {
            lastZoom = level
            UserDefaults.standard.set(p, forKey: "ui.lastZoom")
        }
        zoom = level
    }

    func toggleZoom() {
        zoom = zoom.isZoomed ? .fit : lastZoom
    }

    // MARK: Focus Check

    /// Focus peaking in Loupe, Compare and Survey (⇧F).
    @Published var focusPeaking = UserDefaults.standard.bool(forKey: "focus.peaking") {
        didSet { UserDefaults.standard.set(focusPeaking, forKey: "focus.peaking") }
    }
    @Published var focusSensitivity = FocusPeaking.Sensitivity(
        rawValue: UserDefaults.standard.object(forKey: "focus.sensitivity") as? Int ?? 1) ?? .medium {
        didSet { UserDefaults.standard.set(focusSensitivity.rawValue, forKey: "focus.sensitivity") }
    }
    /// Bumped by Zoom to Sharpest Area (⇧Z); the Loupe zooms in when it changes.
    @Published private(set) var focusZoomToken = 0

    func toggleFocusPeaking() {
        focusPeaking.toggle()
        if focusPeaking, viewMode == .grid || viewMode == .develop || viewMode == .print, selectedPhotoID != nil {
            setViewMode(.loupe)
        }
    }

    /// Loupe at 100% on the photo's sharpest area.
    func zoomToSharpest() {
        guard selectedPhotoID != nil else { return }
        if viewMode != .loupe { setViewMode(.loupe) }
        focusZoomToken += 1
    }
    @Published private(set) var presets: [DevelopPreset] = []
    @Published var settingsSheet: SettingsSheet?
    /// Settings copied with Copy Settings (and which groups to paste).
    @Published private(set) var copiedSettings: (settings: DevelopSettings, groups: Set<SettingsGroup>)?
    @Published var errorMessage: String?

    let develop = DevelopSession()
    let cropTool = CropToolState()
    /// Background exports (top bar shows progress).
    let exportQueue = ExportQueue()

    /// Side panels (Tab) and filmstrip (Shift-Tab hides everything), remembered.
    @Published var showSidePanels = UserDefaults.standard.object(forKey: "ui.sidePanels") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSidePanels, forKey: "ui.sidePanels") }
    }
    @Published var showFilmstrip = UserDefaults.standard.object(forKey: "ui.filmstrip") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showFilmstrip, forKey: "ui.filmstrip") }
    }
    /// Last Library view, restored when switching back from Develop.
    private var lastLibraryMode: ViewMode = .grid

    var isDevelopModule: Bool { viewMode == .develop }
    var isPrintModule: Bool { viewMode == .print }

    /// Print module state (paper, layout, paper profile, preview).
    let printModel = PrintModel()

    /// Tethered capture (hot folder), nil when off.
    @Published var tether: TetherState?
    @Published var showTetherSheet = false
    /// Auto-Rotate Portraits for new photos (UserDefaults `orient.auto`, on by default).
    @Published var autoRotatePortraits = LibraryStore.autoRotateEnabled {
        didSet { UserDefaults.standard.set(autoRotatePortraits, forKey: LibraryStore.autoRotateKey) }
    }
    /// Auto-Rotate running in the background (top bar).
    @Published var orientProgress: BatchProgress?
    /// Help ▸ LumaGrader Guide (Features / Mac Security / About), nil = closed.
    @Published var guideTab: GuideView.Tab?
    /// Develop settings for each new tethered shot (None / Same as Previous / a preset).
    @Published var tetherDevelop = TetherDevelop(stored: UserDefaults.standard.string(forKey: "tether.develop")) {
        didSet { UserDefaults.standard.set(tetherDevelop.stored, forKey: "tether.develop") }
    }
    /// Jump to each new shot (Loupe, or stay in Develop).
    @Published var tetherShowNew = UserDefaults.standard.object(forKey: "tether.showNew") as? Bool ?? true {
        didSet { UserDefaults.standard.set(tetherShowNew, forKey: "tether.showNew") }
    }
    var tetherWatcher: TetherWatcher?

    /// Module picker: Library.
    func showLibrary() {
        setViewMode(lastLibraryMode)
    }

    let catalog: Catalog?
    /// Where Catalog.sqlite lives (for backups); nil when the catalog didn't open.
    let catalogURL: URL?
    private var selectionAnchor: Int64?
    /// JPEGs hidden behind a RAW with the same name (when stacking is on).
    private var stackedJpegIDs: Set<Int64> = []
    /// RAWs that have a JPEG twin.
    private(set) var pairedRawIDs: Set<Int64> = []

    init() {
        // Stored lets first (self can't be used before they're set), messages after.
        var opened: Catalog?
        var openedURL: URL?
        var problem: String?
        do {
            let url = try Catalog.defaultURL()
            do {
                try CatalogBackup.applyPendingRestore(catalog: url)
            } catch {
                problem = "Couldn't restore the backup: \(error.localizedDescription) Your current catalog was kept."
            }
            opened = try Catalog(url: url)
            openedURL = url
        } catch {
            problem = error.localizedDescription
        }
        catalog = opened
        catalogURL = openedURL
        if let problem { errorMessage = problem }
        develop.onSave = { [weak self] id, settings in
            self?.saveDevelop(settings, photoID: id)
        }
        reloadFolders()
        reloadPresets()
        reloadCollections()
        reloadPeople()
        selectedFolderID = folders.first?.id
        loadPhotos() // didSet doesn't run inside init
        scheduleAutoBackup()
    }

    // MARK: - Derived

    var visiblePhotos: [Photo] {
        let list = photos.filter { !stackedJpegIDs.contains($0.id) && matchesFilters($0) }
        guard sortByScore, !analysis.isEmpty else { return list }
        // Stable: equal scores keep file order.
        return list.enumerated().sorted { a, b in
            let sa = analysis[a.element.id]?.score ?? -1, sb = analysis[b.element.id]?.score ?? -1
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map(\.element)
    }

    /// Every photo in the folder in file order (stacked JPEGs hidden), ignoring filters.
    var folderPhotos: [Photo] {
        photos.filter { !stackedJpegIDs.contains($0.id) }
    }

    var selectedPhoto: Photo? { photo(withID: selectedPhotoID) }
    var compareLeft: Photo? { photo(withID: compareLeftID) }

    var selectedFolder: Folder? {
        guard let id = selectedFolderID else { return nil }
        return folders.first { $0.id == id }
    }

    var selectedCollection: PhotoCollection? {
        guard let id = selectedCollectionID else { return nil }
        return collections.first { $0.id == id }
    }

    /// A folder or a collection is showing.
    var hasSource: Bool { selectedFolderID != nil || selectedCollectionID != nil }

    var pickCount: Int { photos.filter { $0.flag == .pick && !stackedJpegIDs.contains($0.id) }.count }
    var rejectCount: Int { photos.filter { $0.flag == .reject && !stackedJpegIDs.contains($0.id) }.count }
    var selectionCount: Int { selectedIDs.count }

    func isSelected(_ id: Int64) -> Bool { selectedIDs.contains(id) }

    /// Next and previous photos, for preloading.
    func neighbors(of id: Int64) -> [Photo] {
        let list = visiblePhotos
        guard let index = list.firstIndex(where: { $0.id == id }) else { return [] }
        return [index + 1, index - 1].compactMap { list.indices.contains($0) ? list[$0] : nil }
    }

    private func photo(withID id: Int64?) -> Photo? {
        guard let id else { return nil }
        return photos.first { $0.id == id }
    }

    private func matchesFilters(_ photo: Photo) -> Bool {
        guard photo.rating >= minRating else { return false }
        switch labelFilter {
        case .any: break
        case .only(let label): guard photo.label == label else { return false }
        case .unlabeled: guard photo.label == .none else { return false }
        }
        if personFilter != nil, !personPaths.contains(photo.url.path) { return false }
        if !searchText.isEmpty {
            let haystack = ([photo.fileName, photo.meta.title, photo.meta.caption, photo.meta.creator]
                + photo.meta.keywords).joined(separator: " ").lowercased()
            let words = searchText.lowercased().split(separator: " ")
            guard words.allSatisfy({ haystack.contains($0) }) else { return false }
        }
        switch flagFilter {
        case .all: return true
        case .picks: return photo.flag == .pick
        case .unflagged: return photo.flag == .unflagged
        case .rejected: return photo.flag == .reject
        }
    }

    // MARK: - Folders

    @MainActor
    func addFolder(_ url: URL) async {
        guard let catalog else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let files = try await Task.detached(priority: .userInitiated) {
                try FolderScanner.scan(url)
            }.value
            let folderID = try catalog.addFolder(path: url.path)
            try catalog.addPhotos(folderID: folderID, files: files)
            reloadFolders()
            if selectedFolderID == folderID {
                loadPhotos()
            } else {
                selectedFolderID = folderID
            }
            autoRotateNew(folderID: folderID)
        } catch {
            errorMessage = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func reloadFolders() {
        guard let catalog else { return }
        do {
            folders = try catalog.folders()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadPhotos() {
        develop.flushSave()
        guard let catalog, hasSource else {
            photos = []
            rebuildStacks()
            select(nil)
            return
        }
        cancelCulling()
        do {
            if let collectionID = selectedCollectionID {
                photos = try catalog.photos(collectionID: collectionID)
                analysis = (try? catalog.analysis(collectionID: collectionID)) ?? [:]
            } else if let folderID = selectedFolderID {
                photos = try catalog.photos(folderID: folderID)
                analysis = (try? catalog.analysis(folderID: folderID)) ?? [:]
            }
        } catch {
            photos = []
            analysis = [:]
            errorMessage = error.localizedDescription
        }
        rebuildStacks()
        if let id = selectedPhotoID, photos.contains(where: { $0.id == id }) {
            selectedIDs = selectedIDs.filter { id in photos.contains { $0.id == id } }
        } else {
            select(visiblePhotos.first?.id)
        }
        compareLeftID = nil
        viewMode = .grid
    }

    private func rebuildStacks() {
        guard stackRawJpeg else {
            stackedJpegIDs = []
            pairedRawIDs = []
            return
        }
        var rawByStem: [String: Int64] = [:]
        for photo in photos where photo.isRaw {
            rawByStem[photo.stemKey] = photo.id
        }
        var hidden: Set<Int64> = []
        var paired: Set<Int64> = []
        for photo in photos where !photo.isRaw {
            if let rawID = rawByStem[photo.stemKey] {
                hidden.insert(photo.id)
                paired.insert(rawID)
            }
        }
        stackedJpegIDs = hidden
        pairedRawIDs = paired
        if let id = selectedPhotoID, hidden.contains(id) {
            select(visiblePhotos.first?.id)
        }
        selectedIDs.subtract(hidden)
    }

    // MARK: - Selection

    func select(_ id: Int64?) {
        selectedPhotoID = id
        selectedIDs = id.map { [$0] } ?? []
        selectionAnchor = id
    }

    /// Grid click: plain = select one, ⌘ = add/remove, ⇧ = range.
    func click(_ photo: Photo, command: Bool, shift: Bool) {
        if shift, let anchor = selectionAnchor ?? selectedPhotoID {
            let range = idsBetween(anchor, photo.id)
            selectedIDs = command ? selectedIDs.union(range) : Set(range)
            selectedIDs.insert(photo.id)
            selectedPhotoID = photo.id
        } else if command {
            if selectedIDs.contains(photo.id), selectedIDs.count > 1 {
                selectedIDs.remove(photo.id)
                if selectedPhotoID == photo.id {
                    selectedPhotoID = visiblePhotos.first { selectedIDs.contains($0.id) }?.id
                }
            } else {
                selectedIDs.insert(photo.id)
                selectedPhotoID = photo.id
            }
            selectionAnchor = photo.id
        } else {
            select(photo.id)
        }
    }

    func selectAll() {
        let ids = visiblePhotos.map(\.id)
        guard !ids.isEmpty else { return }
        selectedIDs = Set(ids)
        if selectedPhotoID == nil || !selectedIDs.contains(selectedPhotoID!) {
            selectedPhotoID = ids.first
        }
    }

    /// Right-click on a photo outside the selection selects just that photo.
    func prepareContextMenu(for photo: Photo) {
        if !selectedIDs.contains(photo.id) { select(photo.id) }
    }

    private func idsBetween(_ a: Int64, _ b: Int64) -> [Int64] {
        let list = visiblePhotos
        guard let i = list.firstIndex(where: { $0.id == a }),
              let j = list.firstIndex(where: { $0.id == b }) else { return [b] }
        return list[min(i, j)...max(i, j)].map(\.id)
    }

    /// Photos that actions (rating, flags, edits, export) apply to: every selected photo
    /// (Grid or filmstrip), otherwise the active one.
    var targetIDs: [Int64] {
        // Survey: flags and ratings go to the photo you're looking at, like Lightroom.
        if selectedIDs.count > 1, viewMode != .survey {
            return visiblePhotos.map(\.id).filter { selectedIDs.contains($0) }
        }
        return selectedPhotoID.map { [$0] } ?? []
    }

    var targetCount: Int { targetIDs.count }

    func selectNone() {
        if viewMode == .grid {
            select(nil)
        } else {
            select(selectedPhotoID)
        }
    }

    /// Selects every shown photo with this flag (e.g. all Picks, to export them).
    func selectFlagged(_ flag: Flag) {
        let ids = visiblePhotos.filter { $0.flag == flag }.map(\.id)
        guard !ids.isEmpty else { return }
        selectedIDs = Set(ids)
        if selectedPhotoID == nil || !selectedIDs.contains(selectedPhotoID!) { selectedPhotoID = ids.first }
    }

    func invertSelection() {
        let ids = visiblePhotos.map(\.id).filter { !selectedIDs.contains($0) }
        guard !ids.isEmpty else { return }
        selectedIDs = Set(ids)
        selectedPhotoID = ids.first
    }

    // MARK: - Rating & flags

    func setRating(_ rating: Int) {
        let targets = targetIDs
        guard let catalog, !targets.isEmpty else { return }
        do {
            try catalog.setRating(rating, photoIDs: targets)
            let value = min(max(rating, 0), 5)
            updatePhotos(targets) { $0.rating = value }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sets the label on every target photo; if they all have it already, removes it
    /// (pressing 6 twice clears Red, like Lightroom).
    func setLabel(_ label: ColorLabel) {
        let targets = targetIDs
        guard let catalog, !targets.isEmpty else { return }
        let targetSet = Set(targets)
        let allHaveIt = label != .none && photos.filter { targetSet.contains($0.id) }.allSatisfy { $0.label == label }
        let value: ColorLabel = allHaveIt ? .none : label
        do {
            try catalog.setLabel(value, photoIDs: targets)
            updatePhotos(targets) { $0.label = value }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// True when a filter hides some photos (for the Clear / Show all buttons).
    var isFiltering: Bool {
        flagFilter != .all || minRating > 0 || labelFilter != .any || personFilter != nil || !searchText.isEmpty
    }

    func clearFilters() {
        flagFilter = .all
        minRating = 0
        labelFilter = .any
        personFilter = nil
        searchText = ""
    }

    func setFlag(_ flag: Flag) {
        let targets = targetIDs
        guard let catalog, !targets.isEmpty, let active = selectedPhotoID else { return }
        let listBefore = visiblePhotos
        do {
            try catalog.setFlag(flag, photoIDs: targets)
            updatePhotos(targets) { $0.flag = flag }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if targets.count > 1 {
            // Keep only selected photos that are still visible.
            let visibleIDs = Set(visiblePhotos.map(\.id))
            selectedIDs = selectedIDs.intersection(visibleIDs)
            if !visibleIDs.contains(active) {
                advance(after: active, in: listBefore)
            }
            return
        }
        let stillVisible = visiblePhotos.contains { $0.id == active }
        if autoAdvance || !stillVisible {
            advance(after: active, in: listBefore)
        }
    }

    func updatePhotos(_ ids: [Int64], _ change: (inout Photo) -> Void) {
        let set = Set(ids)
        for index in photos.indices where set.contains(photos[index].id) {
            change(&photos[index])
        }
    }

    /// Select the photo after `id` in `list`; if it was the last, the one before.
    private func advance(after id: Int64, in list: [Photo]) {
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        let visibleIDs = Set(visiblePhotos.map(\.id))
        let after = list[(index + 1)...].first { visibleIDs.contains($0.id) }
        let before = list[..<index].last { visibleIDs.contains($0.id) }
        if let target = after ?? (visibleIDs.contains(id) ? nil : before) {
            moveActive(to: target.id)
        } else if !visibleIDs.contains(id) {
            select(nil)
        }
    }

    // MARK: - Collections

    func reloadCollections() {
        guard let catalog else { return }
        collections = (try? catalog.collections()) ?? []
    }

    func showCollection(_ id: Int64) {
        selectedCollectionID = id
        if selectedFolderID != nil {
            selectedFolderID = nil // didSet loads the collection
        } else {
            loadPhotos()
        }
    }

    /// New collection, optionally with the selected photos. Returns its id.
    @discardableResult
    func createCollection(named name: String, withSelection: Bool) -> Int64? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let catalog, !trimmed.isEmpty else { return nil }
        do {
            let id = try catalog.createCollection(name: trimmed)
            if withSelection { try catalog.addToCollection(id, photoIDs: targetIDs) }
            reloadCollections()
            return id
        } catch {
            errorMessage = "Couldn't create “\(trimmed)”: \(error.localizedDescription)"
            return nil
        }
    }

    func addSelection(toCollection id: Int64) {
        guard let catalog else { return }
        do {
            try catalog.addToCollection(id, photoIDs: targetIDs)
            reloadCollections()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Removes the selected photos from the collection being shown (files and edits stay).
    func removeSelectionFromCollection() {
        guard let catalog, let id = selectedCollectionID else { return }
        do {
            try catalog.removeFromCollection(id, photoIDs: targetIDs)
            reloadCollections()
            loadPhotos()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameCollection(_ id: Int64, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let catalog, !trimmed.isEmpty else { return }
        do {
            try catalog.renameCollection(id: id, name: trimmed)
            reloadCollections()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteCollection(_ id: Int64) {
        guard let catalog else { return }
        do {
            try catalog.deleteCollection(id: id)
            reloadCollections()
            if selectedCollectionID == id {
                selectedCollectionID = nil
                selectedFolderID = folders.first?.id
                if selectedFolderID == nil { loadPhotos() }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Virtual copies

    /// Makes a virtual copy of the active photo (same file, its own edits) and selects it.
    func createVirtualCopy() {
        develop.flushSave()
        guard let catalog, let photo = selectedPhoto else { return }
        do {
            let id = try catalog.createVirtualCopy(of: photo)
            if let collectionID = selectedCollectionID {
                try catalog.addToCollection(collectionID, photoIDs: [id])
                reloadCollections()
            }
            let mode = viewMode
            loadPhotos()
            select(id)
            if mode != .grid { setViewMode(mode) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeVirtualCopy(_ photo: Photo) {
        guard let catalog, photo.isVirtualCopy else { return }
        do {
            try catalog.deleteVirtualCopy(id: photo.id)
            let next = visiblePhotos.first { $0.url == photo.url && $0.id != photo.id }?.id
            loadPhotos()
            select(next ?? visiblePhotos.first?.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Snapshots

    func reloadSnapshots() {
        guard let catalog, let id = develop.photo?.id else {
            snapshots = []
            return
        }
        snapshots = (try? catalog.snapshots(photoID: id)) ?? []
    }

    func saveSnapshot(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let catalog, let id = develop.photo?.id, !trimmed.isEmpty else { return }
        do {
            try catalog.addSnapshot(photoID: id, name: trimmed, settings: develop.settings)
            reloadSnapshots()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applySnapshot(_ snapshot: Snapshot) {
        develop.setPreview(nil)
        develop.replaceSettings(snapshot.settings, label: "Snapshot: \(snapshot.name)")
    }

    func previewSnapshot(_ snapshot: Snapshot?) {
        guard viewMode == .develop else { return }
        develop.setPreview(snapshot?.settings, label: snapshot.map { "Snapshot: \($0.name)" })
    }

    func deleteSnapshot(_ snapshot: Snapshot) {
        guard let catalog else { return }
        try? catalog.deleteSnapshot(id: snapshot.id)
        reloadSnapshots()
    }

    // MARK: - Metadata

    /// Photos the Metadata panel edits: all selected in the Grid, else the active one.
    var metadataTargets: [Photo] {
        targetIDs.compactMap { id in photos.first { $0.id == id } }
    }

    /// Changes metadata of the given photos (the Metadata panel passes the photos that were
    /// selected when editing started).
    func updateMeta(ids: [Int64], _ change: (inout PhotoMeta) -> Void) {
        guard let catalog else { return }
        for photo in ids.compactMap({ id in photos.first { $0.id == id } }) {
            var meta = photo.meta
            change(&meta)
            guard meta != photo.meta else { continue }
            do {
                try catalog.setMeta(meta, photoID: photo.id)
                updatePhotos([photo.id]) { $0.meta = meta }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    // MARK: - AI Cull

    /// Analyses every photo in the folder that hasn't been analysed yet (or all, `redo`).
    @MainActor
    func startCulling(redo: Bool = false) {
        guard let catalog, cullTask == nil else { return }
        let list = folderPhotos
        guard !list.isEmpty else { return }
        cullProgress = (0, list.count)
        cullTask = Task { @MainActor [weak self] in
            var previous: VNFeaturePrintObservation?
            for (index, photo) in list.enumerated() {
                guard let self, !Task.isCancelled else { break }
                // The feature print chain needs every photo, even ones already analysed.
                let needsWork = redo || self.analysis[photo.id] == nil || index > 0 && self.analysis[photo.id]?.distanceToPrevious == nil
                if let image = await ImageLoader.shared.image(for: photo.url, maxPixel: 1024) {
                    let before = previous
                    let result = await Task.detached(priority: .utility) {
                        CullingAnalyzer.analyze(image, previous: before)
                    }.value
                    previous = result.print
                    if needsWork {
                        try? catalog.saveAnalysis(result.analysis, photoID: photo.id)
                        self.analysis[photo.id] = result.analysis
                    }
                } else {
                    previous = nil
                }
                self.cullProgress = (index + 1, list.count)
            }
            self?.cullTask = nil
            self?.cullProgress = nil
        }
    }

    func cancelCulling() {
        cullTask?.cancel()
        cullTask = nil
        cullProgress = nil
    }

    /// What the options would do (for the sheet's preview line).
    func cullPlan(_ options: CullOptions) -> CullPlanner.Plan {
        CullPlanner.plan(folderPhotos, analysis: analysis, options: options)
    }

    /// Applies flags/stars from the analysis. Returns a summary.
    @discardableResult
    func applyCull(_ options: CullOptions) -> [String] {
        guard let catalog else { return [] }
        let plan = cullPlan(options)
        do {
            for flag in [Flag.pick, .reject, .unflagged] {
                let ids = plan.flags.filter { $0.value == flag }.map(\.key)
                guard !ids.isEmpty else { continue }
                try catalog.setFlag(flag, photoIDs: ids)
                updatePhotos(ids) { $0.flag = flag }
            }
            for stars in 1...5 {
                let ids = plan.ratings.filter { $0.value == stars }.map(\.key)
                guard !ids.isEmpty else { continue }
                try catalog.setRating(stars, photoIDs: ids)
                updatePhotos(ids) { $0.rating = stars }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        return plan.summary.isEmpty ? ["Nothing to change."] : plan.summary
    }

    // MARK: - Develop

    private func saveDevelop(_ settings: DevelopSettings, photoID: Int64) {
        guard let catalog else { return }
        let previous = photos.first { $0.id == photoID }?.develop
        defer {
            if let previous { autoSyncChanges(from: previous, to: settings, photoID: photoID) }
        }
        do {
            try catalog.setDevelop(settings, photoID: photoID)
            updatePhotos([photoID]) { $0.develop = settings }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Opens the Export sheet for the selected photos (all selected in the Grid,
    /// otherwise the active one), with their latest edits.
    func beginExport() {
        develop.flushSave()
        let chosen = targetPhotos
        guard !chosen.isEmpty else { return }
        exportPhotos = chosen
    }

    /// The target photos with their latest edits.
    /// File ▸ Print… (⌘P): the selected photos, one per page, with the Print module settings.
    @MainActor
    func printSelected() {
        let chosen = targetPhotos
        guard !chosen.isEmpty else { return }
        printModel.print(chosen)
    }

    /// File ▸ Page Setup… (⇧⌘P)
    @MainActor
    func pageSetup() {
        printModel.pageSetup()
    }

    private var targetPhotos: [Photo] {
        develop.flushSave()
        return targetIDs.compactMap { id in photos.first { $0.id == id } }
    }

    /// Export straight away with a saved export preset (right-click › Export, File menu).
    /// A preset without a folder asks for one.
    @MainActor
    func export(with preset: ExportPreset) {
        let chosen = targetPhotos
        guard !chosen.isEmpty else { return }
        var folder: URL?
        if preset.folderPath.isEmpty {
            folder = FolderPicker.chooseFolder(prompt: "Export Here",
                                               message: "“\(preset.name)” has no folder. Where should the photos go?")
            guard folder != nil else { return }
        }
        guard let options = preset.options(defaultFolder: folder) else { return }
        try? FileManager.default.createDirectory(at: options.folder, withIntermediateDirectories: true)
        exportQueue.start(chosen.enumerated().map { ExportQueue.Job(photo: $0.element, number: $0.offset + 1, options: options) })
    }

    var canExportWithPrevious: Bool { !exportQueue.lastOptions.isEmpty && selectedPhotoID != nil }

    /// Same settings (every preset ticked) as the last export, for the selected photos.
    func exportWithPrevious() {
        let chosen = targetPhotos
        let optionSets = exportQueue.lastOptions
        guard !chosen.isEmpty, !optionSets.isEmpty else { return }
        var jobs: [ExportQueue.Job] = []
        for options in optionSets {
            jobs += chosen.enumerated().map { ExportQueue.Job(photo: $0.element, number: $0.offset + 1, options: options) }
        }
        exportQueue.start(jobs)
    }

    // MARK: - Presets, copy & paste

    var canPaste: Bool { copiedSettings != nil && selectedPhotoID != nil }


    /// Settings of the active photo, including unsaved changes in Develop.
    private var activeSettings: DevelopSettings? {
        if let photo = develop.photo, photo.id == selectedPhotoID { return develop.settings }
        return selectedPhoto?.develop
    }

    func copySettings(groups: Set<SettingsGroup>) {
        guard let settings = activeSettings, !groups.isEmpty else { return }
        copiedSettings = (settings, groups)
    }

    func pasteSettings() {
        guard let copied = copiedSettings else { return }
        applyToTargets(label: "Paste Settings") { $0.merging(copied.settings, groups: copied.groups) }
    }

    // MARK: - Batch develop actions (every selected photo)

    /// Latest settings of a photo, including unsaved changes in Develop.
    func currentSettings(of id: Int64) -> DevelopSettings? {
        if let open = develop.photo, open.id == id { return develop.settings }
        return photos.first { $0.id == id }?.develop
    }

    /// ⌥⌘C: copies all settings (except crop, masks and spots) without the dialog.
    func copyAllSettings() {
        guard let settings = activeSettings else { return }
        copiedSettings = (settings, SettingsGroup.defaultSelection)
    }

    var canPasteFromPrevious: Bool {
        guard let previous = previousPhotoID, let active = selectedPhotoID else { return false }
        return previous != active && photos.contains { $0.id == previous }
    }

    /// ⌥⌘V: the settings of the photo you were on before this one.
    func pasteFromPrevious() {
        guard let id = previousPhotoID else { return }
        develop.flushSave()
        guard let source = currentSettings(of: id) else { return }
        applyToTargets(label: "Paste from Previous", skipping: id) {
            $0.merging(source, groups: SettingsGroup.defaultSelection)
        }
    }

    var canSync: Bool { selectedIDs.count > 1 }

    /// ⇧⌘S: the active photo's settings (chosen groups) → the other selected photos.
    /// Auto Sync is in effect (switched on and several photos selected).
    var isAutoSyncing: Bool { autoSync && selectedIDs.count > 1 }

    /// Auto Sync: the groups the active photo just changed go to the other selected photos.
    private func autoSyncChanges(from old: DevelopSettings, to new: DevelopSettings, photoID: Int64) {
        guard isAutoSyncing, photoID == selectedPhotoID, selectedIDs.contains(photoID) else { return }
        let changed = old.changedGroups(comparedTo: new)
        guard !changed.isEmpty else { return }
        applyToTargets(label: "Auto Sync", skipping: photoID) { settings, photo in
            settings.merging(new, groups: Self.groups(changed, from: new, for: photo))
        }
    }

    func syncSettings(groups: Set<SettingsGroup>) {
        guard let source = activeSettings, let active = selectedPhotoID, !groups.isEmpty else { return }
        applyToTargets(label: "Sync Settings", skipping: active) { $0.merging(source, groups: groups) }
    }

    /// ⇧⌘R: back to no edits.
    func resetSettings() {
        develop.setPreview(nil)
        applyToTargets(label: "Reset") { _ in .default }
    }

    /// V in the Library / right-click: Black & White on or off (follows the active photo).
    func toggleBlackWhite() {
        let makeBW = !(activeSettings?.blackWhite ?? false)
        applyToTargets(label: makeBW ? "Black & White" : "Color") { settings in
            var s = settings
            s.blackWhite = makeBW
            return s
        }
    }

    /// ⌘[ / ⌘]: quarter turns.
    func rotate(clockwise: Bool) {
        applyToTargets(label: clockwise ? "Rotate Right" : "Rotate Left") { settings in
            var s = settings
            s.crop = s.crop.rotated(clockwise: clockwise)
            return s
        }
    }

    struct BatchProgress: Equatable {
        let label: String
        var done: Int
        let total: Int
    }

    /// Batch Auto running (top bar shows it).
    @Published private(set) var batchProgress: BatchProgress?
    private var batchTask: Task<Void, Never>?

    /// ⌘U Auto Tone / ⇧⌘U Auto White Balance on every selected photo. The photo open in
    /// Develop (alone) uses the session's own Auto, same as the Auto buttons.
    func autoSettings(tone: Bool, whiteBalance: Bool) {
        guard batchTask == nil, tone || whiteBalance else { return }
        let targets = targetIDs
        if targets.count == 1, viewMode == .develop, develop.photo?.id == targets[0], tone != whiteBalance {
            if tone { develop.autoTone() } else { develop.solveWhiteBalance(at: nil) }
            return
        }
        develop.setPreview(nil)
        develop.flushSave()
        let items: [(id: Int64, url: URL, settings: DevelopSettings)] = targets.compactMap { id in
            guard let photo = photos.first(where: { $0.id == id }), let settings = currentSettings(of: id) else { return nil }
            return (id, photo.url, settings)
        }
        guard !items.isEmpty else { return }
        let label = tone && whiteBalance ? "Auto" : (tone ? "Auto Tone" : "Auto White Balance")
        batchProgress = BatchProgress(label: label, done: 0, total: items.count)
        batchTask = Task { @MainActor [weak self] in
            for item in items {
                if Task.isCancelled { break }
                let result = await Task.detached(priority: .userInitiated) {
                    AutoAdjust.compute(url: item.url, settings: item.settings, tone: tone, whiteBalance: whiteBalance)
                }.value
                guard let self, !Task.isCancelled else { return }
                if let result, var settings = self.currentSettings(of: item.id) {
                    result.apply(to: &settings)
                    self.setSettings(settings, for: item.id, label: label)
                }
                self.batchProgress?.done += 1
            }
            self?.batchProgress = nil
            self?.batchTask = nil
        }
    }

    // MARK: - Photo Merge: HDR

    @Published var showHDRSheet = false
    /// What the HDR merge is doing (nil = not running).
    @Published private(set) var hdrProgress: String?
    @Published var hdrError: String?

    /// 2–9 photos selected.
    var canMergeHDR: Bool { (2...9).contains(targetIDs.count) && hdrProgress == nil }

    func beginHDRMerge() {
        hdrError = nil
        guard canMergeHDR else {
            notice = ("HDR Merge", "Select 2 to 9 photos of the same scene taken at different exposures.")
            return
        }
        showHDRSheet = true
    }

    /// The photos that would be merged, in grid order.
    var hdrPhotos: [Photo] {
        targetIDs.compactMap { id in photos.first { $0.id == id } }
    }

    /// Merges the selected photos, adds the result next to them and selects it.
    func mergeHDR(options: HDRMergeOptions) {
        let sources = hdrPhotos
        guard (2...9).contains(sources.count), hdrProgress == nil, let first = sources.first else { return }
        develop.flushSave()
        hdrError = nil
        hdrProgress = "Starting…"
        let urls = sources.map(\.url)
        Task { @MainActor [weak self] in
            let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let url = try HDRMerge.merge(urls: urls, options: options) { text in
                        Task { @MainActor in self?.hdrProgress = text }
                    }
                    return .success(url)
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.hdrProgress = nil
                self.hdrError = error.localizedDescription
            case .success(let url):
                self.hdrProgress = "Adding to the catalog…"
                self.addMergedPhoto(url, folderID: first.folderID, autoSettings: options.autoSettings)
                self.hdrProgress = nil
                self.showHDRSheet = false
            }
        }
    }

    private func addMergedPhoto(_ url: URL, folderID: Int64, autoSettings: Bool) {
        guard let catalog else { return }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        do {
            _ = try catalog.addPhotos(folderID: folderID, files: [ScannedFile(
                url: url, size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate ?? Date())])
        } catch {
            errorMessage = "The merged photo was saved (\(url.lastPathComponent)) but couldn't be added: \(error.localizedDescription)"
            return
        }
        guard selectedCollectionID == nil, selectedFolderID == folderID else {
            notice = ("HDR Merge", "Saved \(url.lastPathComponent) in its folder.")
            return
        }
        loadPhotos()
        guard let merged = photos.first(where: { $0.url.path == url.path && $0.copyIndex == 0 }) else { return }
        select(merged.id)
        guard autoSettings else { return }
        let id = merged.id
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                AutoAdjust.compute(url: url, settings: .default, tone: true, whiteBalance: false)
            }.value
            guard let self, let result, var settings = self.currentSettings(of: id) else { return }
            result.apply(to: &settings)
            self.setSettings(settings, for: id, label: "Auto Tone")
        }
    }

    func cancelBatch() {
        batchTask?.cancel()
        batchTask = nil
        batchProgress = nil
    }

    /// New settings for one photo: through the Develop session when it's open there
    /// (so it renders and can be undone), otherwise straight to the catalog.
    private func setSettings(_ settings: DevelopSettings, for id: Int64, label: String) {
        if let open = develop.photo, open.id == id {
            develop.replaceSettings(settings, label: label)
            return
        }
        guard let catalog, let photo = photos.first(where: { $0.id == id }), photo.develop != settings else { return }
        do {
            try catalog.setDevelop(settings, photoID: id)
            updatePhotos([id]) { $0.develop = settings }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Preset strength, 0…200 % (Presets panel), remembered.
    @Published var presetAmount: Double = UserDefaults.standard.object(forKey: "ui.presetAmount") as? Double ?? 100 {
        didSet { UserDefaults.standard.set(presetAmount, forKey: "ui.presetAmount") }
    }

    /// The last preset click, so its Amount can still be changed afterwards
    /// (while the photo hasn't been edited in another way).
    private var lastPresetApplication: (preset: DevelopPreset, baselines: [Int64: DevelopSettings],
                                        results: [Int64: DevelopSettings])?

    var lastAppliedPresetName: String? { lastPresetApplication?.preset.name }

    func applyPreset(_ preset: DevelopPreset) {
        develop.setPreview(nil)
        var baselines: [Int64: DevelopSettings] = [:]
        var results: [Int64: DevelopSettings] = [:]
        let amount = presetAmount / 100
        applyToTargets(label: "Preset: \(preset.name)") { current, photo in
            let next = current.applying(preset.settings,
                                        groups: Self.groups(preset.groups, from: preset.settings, for: photo),
                                        amount: amount)
            baselines[photo.id] = current
            results[photo.id] = next
            return next
        }
        lastPresetApplication = (preset, baselines, results)
    }

    /// Hovering a preset shows it on the photo in Develop (nil = stop).
    func previewPreset(_ preset: DevelopPreset?) {
        guard viewMode == .develop, let photo = develop.photo else { return }
        guard let preset else {
            develop.setPreview(nil)
            return
        }
        let groups = Self.groups(preset.groups, from: preset.settings, for: photo)
        develop.setPreview(develop.settings.applying(preset.settings, groups: groups, amount: presetAmount / 100),
                           label: preset.name)
    }

    /// While dragging the Amount slider: preview the last applied preset at the new amount.
    func previewPresetAmount(_ value: Double) {
        presetAmount = min(max(value, 0), 200)
        guard let last = lastPresetApplication, let photo = develop.photo,
              let base = last.baselines[photo.id], develop.settings == last.results[photo.id] else { return }
        let groups = Self.groups(last.preset.groups, from: last.preset.settings, for: photo)
        develop.setPreview(base.applying(last.preset.settings, groups: groups, amount: presetAmount / 100),
                           label: "\(last.preset.name) \(Int(presetAmount.rounded()))%")
    }

    /// Amount slider released: re-apply the last preset at the new amount to the photos it
    /// was applied to (skipping any edited since).
    func commitPresetAmount() {
        develop.setPreview(nil)
        guard let catalog, let last = lastPresetApplication else { return }
        var results = last.results
        for (id, base) in last.baselines {
            let isOpen = develop.photo?.id == id
            guard let photo = isOpen ? develop.photo : photos.first(where: { $0.id == id }) else { continue }
            let current = isOpen ? develop.settings : photo.develop
            guard current == last.results[id] else { continue }
            let groups = Self.groups(last.preset.groups, from: last.preset.settings, for: photo)
            let next = base.applying(last.preset.settings, groups: groups, amount: presetAmount / 100)
            if isOpen {
                develop.replaceSettings(next, label: "Preset: \(last.preset.name) \(Int(presetAmount.rounded()))%")
            } else {
                do {
                    try catalog.setDevelop(next, photoID: id)
                    updatePhotos([id]) { $0.develop = next }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            results[id] = next
        }
        lastPresetApplication = (last.preset, last.baselines, results)
    }

    /// White balance in a preset is either Kelvin (RAW) or a −100…100 shift (JPEG and other
    /// files); it is skipped on photos of the other kind, like Lightroom.
    static func groups(_ groups: Set<SettingsGroup>, from settings: DevelopSettings,
                               for photo: Photo) -> Set<SettingsGroup> {
        guard groups.contains(.whiteBalance), let temperature = settings.temperature else { return groups }
        let isKelvin = temperature > 100
        guard isKelvin != photo.isRaw else { return groups }
        var result = groups
        result.remove(.whiteBalance)
        return result
    }

    // MARK: Preset import

    @Published var isImportingPresets = false
    @Published var notice: (title: String, message: String)?

    /// Asks for preset files (.xmp, .lrtemplate, .dng, .zip) and adds them.
    @MainActor
    func chooseAndImportPresets() {
        let panel = NSOpenPanel()
        panel.title = "Import Presets"
        panel.message = "Choose presets (.xmp, .lrtemplate, .dng) or a .zip pack"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = PresetImporter.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importPresets(from: panel.urls)
    }

    @MainActor
    func importPresets(from urls: [URL]) {
        guard let catalog, !isImportingPresets else { return }
        isImportingPresets = true
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                PresetImporter.importFiles(urls)
            }.value
            // Same name as an existing preset → replaced (re-importing a pack updates it);
            // duplicates inside one import get " (2)".
            var names = Set<String>()
            var added: [String] = []
            var skippedNotes: [String] = []
            var failures = result.failures.map { "\($0.file): \($0.reason)" }
            for preset in result.presets {
                let name = Self.uniqueName(preset.name, taken: names)
                do {
                    try catalog.savePreset(name: name, settings: preset.settings, groups: preset.groups)
                    names.insert(name.lowercased())
                    added.append(name)
                    if !preset.skipped.isEmpty {
                        skippedNotes.append("\(name): \(preset.skipped.joined(separator: ", "))")
                    }
                } catch {
                    failures.append("\(preset.name): \(error.localizedDescription)")
                }
            }
            reloadPresets()
            isImportingPresets = false

            var lines: [String] = []
            if !skippedNotes.isEmpty {
                lines.append("Not supported yet (skipped):")
                lines += skippedNotes.prefix(12).map { "• \($0)" }
                if skippedNotes.count > 12 { lines.append("• …and \(skippedNotes.count - 12) more") }
            }
            if !failures.isEmpty {
                if !lines.isEmpty { lines.append("") }
                lines.append("Couldn't import:")
                lines += failures.prefix(12).map { "• \($0)" }
                if failures.count > 12 { lines.append("• …and \(failures.count - 12) more") }
            }
            let title = added.isEmpty
                ? "No presets imported"
                : "Imported \(added.count) preset\(added.count == 1 ? "" : "s")"
            notice = (title, lines.joined(separator: "\n"))
        }
    }

    private static func uniqueName(_ name: String, taken: Set<String>) -> String {
        let base = name.isEmpty ? "Imported Preset" : name
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) (\(n))".lowercased()) { n += 1 }
        return "\(base) (\(n))"
    }

    func savePreset(name: String, groups: Set<SettingsGroup>) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let catalog, let settings = activeSettings, !trimmed.isEmpty, !groups.isEmpty else { return }
        do {
            try catalog.savePreset(name: trimmed, settings: settings, groups: groups)
            reloadPresets()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deletePreset(_ preset: DevelopPreset) {
        guard let catalog else { return }
        do {
            try catalog.deletePreset(id: preset.id)
            reloadPresets()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadPresets() {
        guard let catalog else { return }
        presets = (try? catalog.presets()) ?? []
    }

    /// Changes settings on the target photos. The photo open in Develop goes through its
    /// session (so it renders and can be undone); the others are saved directly.
    private func applyToTargets(label: String? = nil, skipping: Int64? = nil,
                                _ change: (DevelopSettings) -> DevelopSettings) {
        applyToTargets(label: label, skipping: skipping) { settings, _ in change(settings) }
    }

    private func applyToTargets(label: String? = nil, skipping: Int64? = nil,
                                _ change: (DevelopSettings, Photo) -> DevelopSettings) {
        guard let catalog else { return }
        for id in targetIDs where id != skipping {
            if let open = develop.photo, open.id == id {
                develop.replaceSettings(change(develop.settings, open), label: label)
                continue
            }
            guard let photo = photos.first(where: { $0.id == id }) else { continue }
            let updated = change(photo.develop, photo)
            guard updated != photo.develop else { continue }
            do {
                try catalog.setDevelop(updated, photoID: id)
                updatePhotos([id]) { $0.develop = updated }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    func undo() {
        if viewMode == .develop { develop.undo() }
    }

    func redo() {
        if viewMode == .develop { develop.redo() }
    }

    // MARK: - Navigation & views

    func moveSelection(by delta: Int) {
        // Survey: ← → move between the photos being surveyed.
        let list = viewMode == .survey ? surveyPhotos : visiblePhotos
        guard !list.isEmpty else { return }
        guard let current = selectedPhotoID,
              let index = list.firstIndex(where: { $0.id == current }) else {
            select(list.first?.id)
            return
        }
        moveActive(to: list[min(max(index + delta, 0), list.count - 1)].id)
    }

    /// In Compare the left photo stays put; elsewhere the selection follows.
    private func moveActive(to id: Int64) {
        if viewMode == .compare || viewMode == .survey {
            selectedPhotoID = id
        } else {
            select(id)
        }
    }

    /// The selected photos shown in Survey, in grid order.
    var surveyPhotos: [Photo] { visiblePhotos.filter { selectedIDs.contains($0.id) } }

    /// Survey: make this photo the active one (flags and ratings go to it).
    func focusSurveyPhoto(_ id: Int64) {
        guard selectedIDs.contains(id) else { return }
        selectedPhotoID = id
    }

    /// Survey: drop a photo from the set (Lightroom's ✕ on a survey frame).
    func removeFromSurvey(_ id: Int64) {
        guard selectedIDs.count > 1 else { return }
        selectedIDs.remove(id)
        if selectedPhotoID == id {
            selectedPhotoID = surveyPhotos.first?.id
        }
        if selectedIDs.count < 2, viewMode == .survey {
            setViewMode(.loupe)
        }
    }

    func open(_ photo: Photo) {
        select(photo.id)
        setViewMode(.loupe)
    }

    func setViewMode(_ mode: ViewMode) {
        if viewMode == .develop, mode != .develop { develop.flushSave() }
        switch mode {
        case .grid:
            viewMode = .grid
        case .loupe, .develop:
            guard selectedPhotoID != nil else { return }
            viewMode = mode
        case .compare:
            enterCompare()
        case .survey:
            guard selectedIDs.count > 1 else {
                notice = ("Survey", "Select 2 or more photos (⌘-click or ⇧-click), then press N.")
                return
            }
            viewMode = .survey
        case .print:
            guard selectedPhotoID != nil else {
                notice = ("Print", "Select a photo to print first.")
                return
            }
            viewMode = .print
            printModel.scanProfiles()
        }
        if viewMode != .develop, viewMode != .print { lastLibraryMode = viewMode }
    }

    /// Left = another selected photo, or the active one with the next as candidate.
    private func enterCompare() {
        let list = visiblePhotos
        guard let active = selectedPhotoID,
              let index = list.firstIndex(where: { $0.id == active }) else { return }
        if let other = list.first(where: { selectedIDs.contains($0.id) && $0.id != active }) {
            compareLeftID = other.id
        } else if index + 1 < list.count {
            compareLeftID = active
            selectedPhotoID = list[index + 1].id
        } else if index > 0 {
            compareLeftID = list[index - 1].id
        } else {
            return
        }
        viewMode = .compare
    }

    func swapCompare() {
        guard let left = compareLeftID, let right = selectedPhotoID else { return }
        compareLeftID = right
        selectedPhotoID = left
    }

    /// Returns true when the key was used.
    func handle(_ command: KeyCommand) -> Bool {
        switch command {
        case .previous: moveSelection(by: -1)
        case .next: moveSelection(by: 1)
        case .escape:
            if viewMode == .develop, develop.activePicker != nil {
                develop.activePicker = nil
            } else if viewMode == .develop, develop.maskingOpen {
                develop.toggleMasking()
            } else if viewMode == .develop, develop.healingOpen {
                develop.toggleHealing()
            } else if viewMode == .develop, develop.cropMode {
                develop.setCropMode(false)
            } else if viewMode == .loupe || viewMode == .develop, zoom.isZoomed {
                zoom = .fit
            } else {
                guard viewMode != .grid else { return false }
                setViewMode(.grid)
            }
        case .enter where viewMode == .develop && develop.cropMode:
            develop.setCropMode(false)
        case .enter, .loupe:
            guard selectedPhotoID != nil else { return false }
            setViewMode(.loupe)
        case .grid: setViewMode(.grid)
        case .compare: setViewMode(.compare)
        case .survey: setViewMode(.survey)
        case .develop: setViewMode(.develop)
        case .focusPeaking:
            guard selectedPhotoID != nil else { return false }
            toggleFocusPeaking()
        case .zoomToFocus:
            guard selectedPhotoID != nil else { return false }
            zoomToSharpest()
        case .space:
            guard selectedPhotoID != nil else { return false }
            setViewMode(viewMode == .grid ? .loupe : .grid)
        case .beforeAfter:
            guard viewMode == .develop else { return false }
            develop.toggleBeforeAfter()
        case .selectAll:
            guard viewMode == .grid else { return false }
            selectAll()
        case .crop:
            guard selectedPhotoID != nil else { return false }
            if viewMode != .develop {
                setViewMode(.develop)
                develop.load(selectedPhoto) // load now so crop mode isn't reset by the view's load
            }
            develop.setCropMode(!develop.cropMode)
        case .zoom:
            switch viewMode {
            case .develop:
                guard !develop.cropMode else { return false }
                toggleZoom()
            case .loupe: toggleZoom()
            case .grid:
                guard selectedPhotoID != nil else { return false }
                zoom = lastZoom
                setViewMode(.loupe)
            case .compare, .survey, .print: return false
            }
        case .togglePanels:
            showSidePanels.toggle()
        case .toggleAllPanels:
            let anyShown = showSidePanels || showFilmstrip
            showSidePanels = !anyShown
            showFilmstrip = !anyShown
        case .fullScreen:
            NSApp.keyWindow?.toggleFullScreen(nil)
        case .whiteBalancePicker:
            guard selectedPhotoID != nil else { return false }
            if viewMode != .develop {
                setViewMode(.develop)
                develop.load(selectedPhoto)
            }
            develop.togglePicker(.whiteBalance)
        case .blackWhite:
            guard selectedPhotoID != nil else { return false }
            if viewMode == .develop, selectedIDs.count <= 1 {
                develop.toggleBlackWhite()
            } else {
                toggleBlackWhite()
            }
        case .clipping:
            guard viewMode == .develop else { return false }
            develop.toggleClipping()
        case .masking:
            guard selectedPhotoID != nil else { return false }
            if viewMode != .develop {
                setViewMode(.develop)
                develop.load(selectedPhoto)
            }
            develop.toggleMasking()
        case .newMask(let kind):
            guard selectedPhotoID != nil else { return false }
            if viewMode != .develop {
                setViewMode(.develop)
                develop.load(selectedPhoto)
            }
            develop.createMask(kind)
        case .maskOverlay:
            guard viewMode == .develop, develop.maskingOpen else { return false }
            develop.showMaskOverlay.toggle()
        case .compareLayout:
            guard viewMode == .develop else { return false }
            develop.cycleCompareLayout()
        case .healing:
            guard selectedPhotoID != nil else { return false }
            if viewMode != .develop {
                setViewMode(.develop)
                develop.load(selectedPhoto)
            }
            develop.toggleHealing()
        case .delete:
            if viewMode == .develop, develop.healingOpen {
                guard let id = develop.selectedSpotID else { return false }
                develop.deleteSpot(id)
            } else if viewMode == .develop, develop.maskingOpen || develop.cropMode {
                return false
            } else {
                // Delete Photo… (Move to Trash / Remove from Catalog), like Lightroom.
                guard selectedPhotoID != nil, viewMode != .print else { return false }
                Task { @MainActor [weak self] in self?.confirmDeleteSelected() }
            }
        case .smaller, .larger:
            guard viewMode == .develop else { return false }
            var factor = 1 / 1.18
            if case .larger = command { factor = 1.18 }
            if develop.healingOpen {
                develop.resizeSpot(by: factor)
            } else if develop.isEditingDrawnMask, develop.selectedComponent?.kind == .brush {
                develop.brush.size = min(max(develop.brush.size * factor, 0.003), 0.3)
            } else {
                return false
            }
        case .rating(let value): setRating(value)
        case .label(let value): setLabel(value)
        case .pick: setFlag(.pick)
        case .reject: setFlag(.reject)
        case .unflag: setFlag(.unflagged)
        }
        return true
    }
}
