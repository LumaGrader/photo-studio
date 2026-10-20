import Foundation

/// Auto-Rotate Portraits: vertical shots saved sideways (camera auto-rotate off) are turned
/// upright with a quarter turn in their develop settings (the file isn't touched; Rotate
/// Left / Right undoes it).
extension LibraryStore {
    static let autoRotateKey = "orient.auto"

    /// On unless turned off (Photo ▸ Auto-Rotate Portraits on Import). Readable off the main thread.
    static var autoRotateEnabled: Bool {
        UserDefaults.standard.object(forKey: autoRotateKey) as? Bool ?? true
    }

    /// New photos of a folder that haven't been checked yet (after Import / Add Folder / Synchronize).
    func autoRotateNew(folderID: Int64) {
        guard autoRotatePortraits, let catalog,
              let folderPhotos = try? catalog.photos(folderID: folderID) else { return }
        let checked = (try? catalog.orientCheckedPhotoIDs()) ?? []
        let candidates = folderPhotos.filter { !checked.contains($0.id) && !$0.isVirtualCopy }
        runAutoRotate(candidates, label: "Auto-Rotate")
    }

    /// Photo ▸ Auto-Rotate Portraits: checks the selected photos again.
    func autoRotateSelected() {
        let chosen = targetIDs.compactMap { id in photos.first { $0.id == id } }.filter { !$0.isVirtualCopy }
        guard !chosen.isEmpty else { return }
        runAutoRotate(chosen, label: "Auto-Rotate", reportNothing: true)
    }

    private func runAutoRotate(_ candidates: [Photo], label: String, reportNothing: Bool = false) {
        guard !candidates.isEmpty, orientProgress == nil else { return }
        let items = candidates.map { (id: $0.id, url: $0.url) }
        orientProgress = BatchProgress(label: label, done: 0, total: items.count)
        Task { @MainActor [weak self] in
            var turned = 0
            var checkedIDs: [Int64] = []
            for (index, item) in items.enumerated() {
                let turn = await Task.detached(priority: .utility) { AutoOrient.detect(item.url) }.value
                guard let self else { return }
                checkedIDs.append(item.id)
                if turn != .upright, self.applyTurn(turn, to: item.id) { turned += 1 }
                self.orientProgress?.done = index + 1
            }
            guard let self else { return }
            try? self.catalog?.markOrientChecked(checkedIDs)
            self.orientProgress = nil
            if turned > 0 {
                self.flashBackupStatus(turned == 1 ? "1 portrait turned upright" : "\(turned) portraits turned upright")
            } else if reportNothing {
                self.flashBackupStatus("No sideways portraits found")
            }
        }
    }

    /// Turns a photo that hasn't been turned yet (an existing quarter turn wins).
    @discardableResult
    func applyTurn(_ turn: AutoOrient.Turn, to id: Int64) -> Bool {
        guard let catalog, turn != .upright, var settings = currentSettings(of: id),
              settings.crop.rotate90 == 0 else { return false }
        settings.crop = settings.crop.rotated(clockwise: turn == .clockwise)
        if let open = develop.photo, open.id == id {
            develop.replaceSettings(settings, label: "Auto-Rotate")
            return true
        }
        do {
            try catalog.setDevelop(settings, photoID: id)
            updatePhotos([id]) { $0.develop = settings }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
