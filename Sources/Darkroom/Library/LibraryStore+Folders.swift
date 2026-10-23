import AppKit

/// Remove Folder: like Lightroom, take a folder out of the catalog, or move it to the Trash.
/// Either way its photos, edits, ratings and collection entries leave the catalog.
extension LibraryStore {
    /// Right-click a folder ▸ Remove Folder…: confirms, then removes or trashes it.
    @MainActor
    func confirmRemoveFolder(_ folder: Folder) {
        guard let catalog else { return }
        develop.flushSave()
        let count = (try? catalog.photoCount(folderID: folder.id)) ?? 0
        // Trashing a folder that holds another catalog folder would take that one's files too.
        let holdsOther = folders.contains {
            $0.id != folder.id && $0.url.path.hasPrefix(folder.url.path + "/")
        }
        let canTrash = folder.exists && !holdsOther

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \"\(folder.name)\"?"
        let photos = count == 1 ? "1 photo" : "\(count) photos"
        var info = "Remove from Catalog takes the folder and its \(photos) out of LumaGrader, with their edits, ratings and collection entries. The files stay on your disk."
        if canTrash {
            info += "\n\nMove to Trash also moves the folder and everything in it to the Trash (you can still restore it from there)."
        } else if holdsOther {
            info += "\n\nThis folder contains another folder in your catalog, so it can only be removed from the catalog."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Remove from Catalog")
        if canTrash { alert.addButton(withTitle: "Move to Trash") }
        alert.addButton(withTitle: "Cancel")
        if canTrash, #available(macOS 11.0, *) {
            alert.buttons[1].hasDestructiveAction = true
        }
        let response = alert.runModal()
        let trash: Bool
        switch response {
        case .alertFirstButtonReturn: trash = false
        case .alertSecondButtonReturn where canTrash: trash = true
        default: return
        }
        removeFolder(folder, trash: trash)
    }

    @MainActor
    private func removeFolder(_ folder: Folder, trash: Bool) {
        guard let catalog else { return }
        if trash {
            do {
                try FileManager.default.trashItem(at: folder.url, resultingItemURL: nil)
            } catch {
                errorMessage = "Couldn't move \(folder.name) to the Trash: \(error.localizedDescription)"
                return
            }
        }
        do {
            try catalog.removeFolder(id: folder.id)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let wasSelected = selectedFolderID == folder.id
        reloadFolders()
        if wasSelected {
            selectedFolderID = folders.first?.id
        }
        loadPhotos()
        flashBackupStatus(trash ? "\(folder.name) moved to the Trash" : "\(folder.name) removed from the catalog")
    }
}
