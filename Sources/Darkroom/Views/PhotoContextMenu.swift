import SwiftUI
import AppKit

/// Right-click menu for photos in the Grid, the filmstrip and the large previews (Loupe,
/// Develop, Compare, Survey), like Lightroom's.
/// Right-clicking a photo outside the selection selects just that photo first; otherwise
/// every action applies to all selected photos.
struct PhotoContextMenu: View {
    let photo: Photo
    @ObservedObject var store: LibraryStore

    var body: some View {
        let count = store.isSelected(photo.id) ? store.selectionCount : 1
        if count > 1 {
            Text("\(count) photos selected")
        }

        Button("Open in Loupe (E)") { store.open(photo) }
        Button("Edit in Develop (D)") {
            store.prepareContextMenu(for: photo)
            store.setViewMode(.develop)
        }

        Divider()

        Menu("Export") {
            Button(count > 1 ? "Export \(count) Photos… (⇧⌘E)" : "Export… (⇧⌘E)") { run { store.beginExport() } }
            Button("Export with Previous (⌥⇧⌘E)") { run { store.exportWithPrevious() } }
                .disabled(store.exportQueue.lastOptions.isEmpty)
            Button(count > 1 ? "Create Proofing Gallery of \(count) Photos…" : "Create Proofing Gallery…") {
                run { store.beginProofingGallery() }
            }
            let presets = ExportPreset.load()
            if !presets.isEmpty {
                Divider()
                ForEach(presets) { preset in
                    Button(preset.name) { run { store.export(with: preset) } }
                }
            }
        }

        Divider()

        Menu("Develop Settings") {
            Button("Auto Tone (⌘U)") { run { store.autoSettings(tone: true, whiteBalance: false) } }
            Button("Auto White Balance (⇧⌘U)") { run { store.autoSettings(tone: false, whiteBalance: true) } }
            Button("Auto Tone + White Balance") { run { store.autoSettings(tone: true, whiteBalance: true) } }
            Button("Match Total Exposures (⌥⇧⌘M)") { run { store.matchTotalExposures() } }
                .disabled(count < 2)
            Divider()
            Button("Copy Settings… (⇧⌘C)") { run { store.settingsSheet = .copy } }
            Button("Copy All Settings (⌥⌘C)") { run { store.copyAllSettings() } }
            Button("Paste Settings (⇧⌘V)") { run { store.pasteSettings() } }
                .disabled(store.copiedSettings == nil)
            Button("Paste from Previous (⌥⌘V)") { run { store.pasteFromPrevious() } }
                .disabled(store.previousPhotoID == nil)
            Button("Sync Settings… (⇧⌘S)") { run { store.settingsSheet = .sync } }
                .disabled(count < 2)
            Divider()
            Button("Convert to Black & White") { run { store.toggleBlackWhite() } }
            Button("Reset (⇧⌘R)") { run { store.resetSettings() } }
        }
        if !store.presets.isEmpty {
            Menu("Develop Preset") {
                ForEach(store.presets) { preset in
                    Button(preset.name) { run { store.applyPreset(preset) } }
                }
            }
        }

        Divider()

        Menu("Set Flag") {
            Button("Pick (P)") { run { store.setFlag(.pick) } }
            Button("Reject (X)") { run { store.setFlag(.reject) } }
            Button("Unflagged (U)") { run { store.setFlag(.unflagged) } }
        }
        Menu("Set Rating") {
            ForEach(0...5, id: \.self) { stars in
                Button(stars == 0 ? "None (0)" : String(repeating: "★", count: stars) + " (\(stars))") {
                    run { store.setRating(stars) }
                }
            }
        }
        Menu("Set Color Label") {
            ForEach(ColorLabel.colors) { label in
                Button(label.key.map { "\(label.name) (\($0))" } ?? label.name) {
                    run { store.setLabel(label) }
                }
            }
            Divider()
            Button("None") { run { store.setLabel(.none) } }
        }
        Menu("Photo Merge") {
            Button("HDR… (⌃H)") { run { store.beginHDRMerge() } }
                .disabled(count < 2 || count > 9)
        }
        Button("Rotate Left (⌘[)") { run { store.rotate(clockwise: false) } }
        Button("Rotate Right (⌘])") { run { store.rotate(clockwise: true) } }

        Divider()

        Button("Create Virtual Copy (⌘')") {
            store.select(photo.id)
            store.createVirtualCopy()
        }
        if photo.isVirtualCopy {
            Button("Remove Virtual Copy", role: .destructive) { store.removeVirtualCopy(photo) }
        }
        Menu("Add to Collection") {
            ForEach(store.collections) { collection in
                Button(collection.name) { run { store.addSelection(toCollection: collection.id) } }
            }
            if !store.collections.isEmpty { Divider() }
            Button("New Collection…") {
                run {
                    if let name = TextPrompt.ask(title: "New Collection", message: "Name:", confirm: "Create") {
                        store.createCollection(named: name, withSelection: true)
                    }
                }
            }
        }
        if store.selectedCollectionID != nil {
            Button("Remove from Collection") { run { store.removeSelectionFromCollection() } }
        }

        Divider()

        Button("Show in Finder") {
            run {
                let urls = store.targetIDs.compactMap { id in store.visiblePhotos.first { $0.id == id }?.url }
                NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [photo.url] : urls)
            }
        }
        Button("Open in Default App") {
            NSWorkspace.shared.open(photo.url)
        }
        Button("Copy File Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(photo.url.path, forType: .string)
        }

        Divider()

        Button(count > 1 ? "Delete \(count) Photos… (⌫)" : "Delete Photo… (⌫)", role: .destructive) {
            run { store.confirmDeleteSelected() }
        }
    }

    /// Selects the right-clicked photo when it isn't part of the selection, then acts.
    @MainActor
    private func run(_ action: () -> Void) {
        // Survey: actions go to the active photo, so make the right-clicked one active.
        if store.viewMode == .survey { store.focusSurveyPhoto(photo.id) }
        store.prepareContextMenu(for: photo)
        action()
    }
}
