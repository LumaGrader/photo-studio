import Foundation
import AppKit

/// File ▸ Create Proofing Gallery… and File ▸ Import Client Picks…
/// The gallery is a folder (and .zip) the client opens in a browser, hearts photos, adds
/// notes and sends back a list; Import Client Picks reads that list and gives the picked
/// photos the Purple label.
extension LibraryStore {
    static let proofingLabel = ColorLabel.purple

    func beginProofingGallery() {
        develop.flushSave()
        let chosen = targetIDs.compactMap { id in photos.first { $0.id == id } }
        guard !chosen.isEmpty else {
            notice = ("Create Proofing Gallery", "Select the photos for the client first (⌘A selects every photo shown).")
            return
        }
        proofingPhotos = chosen
        proofingResult = nil
        proofingError = nil
        showProofingSheet = true
    }

    /// A sensible gallery title: the folder (shoot) name.
    var proofingDefaultTitle: String {
        guard let first = proofingPhotos.first else { return "" }
        let name = first.url.deletingLastPathComponent().lastPathComponent
        // "2026-10-17 Santos Wedding" → "Santos Wedding"
        let parts = name.split(separator: " ", maxSplits: 1)
        if parts.count == 2, parts[0].count == 10, parts[0].filter({ $0 == "-" }).count == 2 { return String(parts[1]) }
        return name
    }

    func createProofingGallery(_ options: ProofingOptions) {
        let chosen = proofingPhotos.map { photo in
            var p = photo
            if let settings = currentSettings(of: photo.id) { p.develop = settings }
            return p
        }
        guard !chosen.isEmpty, proofingProgress == nil else { return }
        try? FileManager.default.createDirectory(at: options.parentFolder, withIntermediateDirectories: true)
        var watermark = WatermarkSettings()
        if options.watermark {
            if let data = UserDefaults.standard.data(forKey: "export.watermark"),
               let saved = try? JSONDecoder().decode(WatermarkSettings.self, from: data) {
                watermark = saved
            }
            watermark.enabled = true
            if !watermark.isUsable {
                watermark.kind = .text
                watermark.text = "PROOF"
            }
        }
        proofingError = nil
        proofingProgress = BatchProgress(label: "Proofing gallery", done: 0, total: chosen.count)
        Task { @MainActor [weak self] in
            let result: Result<ProofingGallery.Result, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    try ProofingGallery.build(photos: chosen, options: options, watermark: watermark) { done, total in
                        Task { @MainActor in self?.proofingProgress = BatchProgress(label: "Proofing gallery", done: done, total: total) }
                    }
                }
            }.value
            guard let self else { return }
            self.proofingProgress = nil
            switch result {
            case .success(let gallery): self.proofingResult = gallery
            case .failure(let error): self.proofingError = error.localizedDescription
            }
        }
    }

    // MARK: - Import Client Picks

    struct PicksMatch {
        let picks: ProofingPicks
        let manifest: ProofingManifest?
        /// Gallery number → catalog photo.
        let photoIDs: [Int: Int64]
        /// Picked numbers that couldn't be matched to a photo.
        let unmatched: [ProofingPicks.Item]

        var favoriteIDs: [Int64] { picks.favorites.compactMap { photoIDs[$0.n] } }
    }

    /// Matches by the gallery's saved list when it was made on this Mac; otherwise by file
    /// name among the photos shown (a name found more than once isn't guessed).
    func matchPicks(_ picks: ProofingPicks) -> PicksMatch {
        let manifest = picks.galleryID.flatMap { ProofingManifest.load(id: $0) }
        var ids: [Int: Int64] = [:]
        var unmatched: [ProofingPicks.Item] = []
        for item in picks.items {
            if let entry = manifest?.entries.first(where: { $0.n == item.n }) {
                ids[item.n] = entry.photoID
                continue
            }
            let name = item.name.components(separatedBy: " · Copy").first ?? item.name
            let found = photos.filter { $0.fileName.caseInsensitiveCompare(name) == .orderedSame && !$0.isVirtualCopy }
            if found.count == 1 {
                ids[item.n] = found[0].id
            } else {
                unmatched.append(item)
            }
        }
        return PicksMatch(picks: picks, manifest: manifest, photoIDs: ids, unmatched: unmatched)
    }

    /// Gives the picked photos the Purple label and remembers the client's notes.
    /// Returns how many photos were labelled.
    @discardableResult
    func applyPicks(_ match: PicksMatch) -> Int {
        guard let catalog else { return 0 }
        let ids = match.favoriteIDs
        guard !ids.isEmpty else { return 0 }
        do {
            try catalog.setLabel(Self.proofingLabel, photoIDs: ids)
            updatePhotos(ids) { $0.label = Self.proofingLabel }
        } catch {
            errorMessage = error.localizedDescription
            return 0
        }
        if var manifest = match.manifest {
            manifest.client = match.picks.client
            manifest.notes = match.picks.notes.map {
                .init(n: $0.n, fileName: $0.name, note: $0.note, favorite: $0.favorite)
            }
            try? manifest.save()
        }
        return ids.count
    }

    /// Library Filter ▸ Purple, to see what the client picked.
    func showClientPicks() {
        labelFilter = .only(Self.proofingLabel)
        if viewMode != .grid { setViewMode(.grid) }
    }

    /// Makes a photo of the gallery the active one (from the notes list), when it's shown.
    func reveal(photoID: Int64) {
        if visiblePhotos.contains(where: { $0.id == photoID }) { select(photoID) }
    }
}
