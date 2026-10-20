import AppKit

/// Delete Photo: like Lightroom, ask whether to move the files to the Trash or only remove
/// them from the catalog. A RAW's hidden JPEG twin (RAW+JPEG stacking) goes with it, and a
/// photo's virtual copies go with the photo. Virtual copies alone are only removed from the
/// catalog (they have no file of their own).
extension LibraryStore {
    enum DeleteChoice {
        case trash, removeFromCatalog
    }

    /// Delete key / right-click ▸ Delete Photo…: confirms, then deletes the target photos.
    @MainActor
    func confirmDeleteSelected() {
        develop.flushSave()
        let chosen = targetIDs.compactMap { id in photos.first { $0.id == id } }
        guard !chosen.isEmpty else { return }

        let masters = chosen.filter { !$0.isVirtualCopy }
        let copiesOnly = masters.isEmpty
        let twins = jpegTwins(of: masters)
        let fileCount = Set((masters + twins).map(\.url.path)).count

        let alert = NSAlert()
        alert.alertStyle = .warning
        if copiesOnly {
            alert.messageText = chosen.count == 1 ? "Remove this virtual copy?" : "Remove \(chosen.count) virtual copies?"
            alert.informativeText = "Only the copies' edits are removed. The original photo and its file stay."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            deletePhotos(chosen, twins: [], choice: .removeFromCatalog)
            return
        }

        alert.messageText = chosen.count == 1
            ? "Delete \"\(chosen[0].fileName)\"?"
            : "Delete \(chosen.count) photos?"
        var info = "Move to Trash deletes the file\(fileCount == 1 ? "" : "s") from your disk (you can still restore from the Trash). "
        info += "Remove from Catalog keeps the file\(fileCount == 1 ? "" : "s") and only removes the photo\(chosen.count == 1 ? "" : "s") and edits from LumaGrader."
        if !twins.isEmpty {
            info += "\n\nIncludes \(twins.count) JPEG\(twins.count == 1 ? "" : "s") stacked with the RAW\(twins.count == 1 ? "" : "s")."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Remove from Catalog")
        alert.addButton(withTitle: "Cancel")
        if #available(macOS 11.0, *) {
            alert.buttons.first?.hasDestructiveAction = true
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn: deletePhotos(chosen, twins: twins, choice: .trash)
        case .alertSecondButtonReturn: deletePhotos(chosen, twins: twins, choice: .removeFromCatalog)
        default: return
        }
    }

    /// The hidden JPEGs stacked under these RAWs.
    private func jpegTwins(of photos: [Photo]) -> [Photo] {
        let stems = Set(photos.filter(\.isRaw).map(\.stemKey))
        guard !stems.isEmpty else { return [] }
        let chosenIDs = Set(photos.map(\.id))
        let visibleIDs = Set(visiblePhotos.map(\.id))
        return self.photos.filter { photo in
            !photo.isRaw && !photo.isVirtualCopy && stems.contains(photo.stemKey)
                && !chosenIDs.contains(photo.id) && !visibleIDs.contains(photo.id)
        }
    }

    @MainActor
    private func deletePhotos(_ chosen: [Photo], twins: [Photo], choice: DeleteChoice) {
        guard let catalog else { return }
        let all = chosen + twins
        // Where to go afterwards: the next photo that stays, else the one before.
        let removedIDs = Set(all.map(\.id))
        let list = visiblePhotos
        let firstIndex = list.firstIndex { removedIDs.contains($0.id) } ?? 0
        let next = list[firstIndex...].first { !removedIDs.contains($0.id) && !sharesFile($0, with: all) }
            ?? list[..<firstIndex].last { !removedIDs.contains($0.id) && !sharesFile($0, with: all) }

        var removable = all
        var failed: [String] = []
        if choice == .trash {
            removable = []
            var trashedPaths: Set<String> = []
            for photo in all {
                if photo.isVirtualCopy || trashedPaths.contains(photo.url.path) {
                    removable.append(photo)
                    continue
                }
                do {
                    try FileManager.default.trashItem(at: photo.url, resultingItemURL: nil)
                    trashedPaths.insert(photo.url.path)
                    removable.append(photo)
                } catch {
                    // A file that's already gone can still leave the catalog.
                    if !FileManager.default.fileExists(atPath: photo.url.path) {
                        removable.append(photo)
                    } else {
                        failed.append("\(photo.fileName): \(error.localizedDescription)")
                    }
                }
            }
        }

        do {
            let masters = removable.filter { !$0.isVirtualCopy }.map(\.id)
            let copies = removable.filter(\.isVirtualCopy).map(\.id)
            try catalog.removePhotos(ids: masters)
            for id in copies { try catalog.deleteVirtualCopy(id: id) }
        } catch {
            errorMessage = error.localizedDescription
        }

        let mode = viewMode
        loadPhotos()
        if let next, photos.contains(where: { $0.id == next.id }) {
            select(next.id)
            if mode != .grid, mode != .compare, mode != .survey { setViewMode(mode) }
        } else if photos.isEmpty {
            setViewMode(.grid)
        }
        if !failed.isEmpty {
            errorMessage = "Couldn't move \(failed.count) file\(failed.count == 1 ? "" : "s") to the Trash:\n" + failed.joined(separator: "\n")
        } else {
            let what = choice == .trash ? "moved to the Trash" : "removed from the catalog"
            flashBackupStatus(removable.count == 1 ? "1 photo \(what)" : "\(removable.count) photos \(what)")
        }
    }

    private func sharesFile(_ photo: Photo, with removed: [Photo]) -> Bool {
        removed.contains { !$0.isVirtualCopy && $0.url == photo.url }
    }
}
