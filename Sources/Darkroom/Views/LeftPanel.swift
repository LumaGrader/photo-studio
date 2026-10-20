import SwiftUI
import AppKit

/// Library: Navigator, Folders, Import/Export. Develop: Navigator, Presets, Copy/Paste.
struct LeftPanel: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    NavigatorSection(session: store.develop)
                    if store.isDevelopModule {
                        PresetsSection()
                        SnapshotsSection(session: store.develop)
                        HistorySection(session: store.develop)
                    } else {
                        FoldersSection()
                        CollectionsSection()
                        PeopleSection()
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if store.isDevelopModule {
                    PanelButton(title: "Copy…") { store.settingsSheet = .copy }
                    PanelButton(title: "Paste") { store.pasteSettings() }
                        .disabled(!store.canPaste)
                        .opacity(store.canPaste ? 1 : 0.5)
                    if store.canSync {
                        PanelButton(title: "Sync…") { store.settingsSheet = .sync }
                            .help("Copy settings from this photo to the other selected photos (⇧⌘S)")
                        Toggle("Auto", isOn: $store.autoSync)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(Theme.smallFont)
                            .help("Auto Sync: every edit to this photo also goes to the other \(store.selectionCount - 1) selected photos")
                    }
                } else {
                    PanelButton(title: "Import…") { store.beginImport() }
                    PanelButton(title: store.selectionCount > 1 ? "Export \(store.selectionCount)…" : "Export…") {
                        store.beginExport()
                    }
                    .help("Export the selected photos (⇧⌘E). ⌘-click or ⇧-click photos to select several.")
                        .disabled(store.selectedPhotoID == nil)
                        .opacity(store.selectedPhotoID == nil ? 0.5 : 1)
                }
            }
            .padding(10)
        }
        .background(Theme.panel)
    }
}

// MARK: - Navigator

struct NavigatorSection: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject var session: DevelopSession
    @State private var image: CGImage?


    /// Develop shows the live edit (not while cropping); Library shows the thumbnail.
    private var shownImage: CGImage? {
        if store.isDevelopModule, !session.cropMode, let live = session.image { return live }
        return image
    }

    var body: some View {
        PanelSection("Navigator", startExpanded: true, accessory: {
            HStack(spacing: 8) {
                ForEach([ZoomLevel.fit, .percent(50), .percent(100), .percent(200)], id: \.self) { level in
                    Button(level.label) { store.pickZoom(level) }
                        .buttonStyle(.plain)
                        .font(Theme.smallFont.weight(.semibold))
                        .foregroundStyle(store.zoom == level ? Theme.textBright : Theme.textDim)
                }
                if case .percent = store.zoom, !ZoomLevel.presets.contains(store.zoom) {
                    Text(store.zoom.label)
                        .font(Theme.smallFont.weight(.semibold))
                        .foregroundStyle(Theme.textBright)
                }
            }
            .disabled(store.selectedPhotoID == nil || store.viewMode == .grid || store.viewMode == .compare
                      || store.viewMode == .survey
                      || (store.isDevelopModule && session.cropMode))
        }) {
            ZStack {
                Color.black.opacity(0.25)
                if let shown = shownImage {
                    Image(decorative: shown, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFit()
                }
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
        }
        .task(id: NavigatorKey(photo: store.selectedPhotoID, develop: store.selectedPhoto?.develop)) {
            guard let photo = store.selectedPhoto else {
                image = nil
                return
            }
            image = await ImageLoader.shared.displayImage(for: photo, maxPixel: ThumbnailDiskCache.maxPixel)
        }
    }

    private struct NavigatorKey: Equatable {
        let photo: Int64?
        let develop: DevelopSettings?
    }
}

// MARK: - Folders

struct FoldersSection: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        PanelSection("Folders", startExpanded: true, accessory: {
            Button {
                if let url = FolderPicker.chooseFolder() {
                    Task { await store.addFolder(url) }
                }
            } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textDim)
            .help("Import a folder (⇧⌘I)")
        }) {
            if store.folders.isEmpty {
                Text("No folders yet. Click + or Import… to add one.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textDim)
            }
            ForEach(store.folders) { folder in
                folderRow(folder)
            }
        }
    }

    private func folderRow(_ folder: Folder) -> some View {
        let selected = folder.id == store.selectedFolderID && store.selectedCollectionID == nil
        return HStack(spacing: 6) {
            Image(systemName: folder.exists ? "folder.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(folder.exists ? Theme.textDim : Color.orange)
            Text(folder.name)
                .font(Theme.bodyFont)
                .foregroundStyle(selected ? Theme.textBright : Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(selected ? Theme.selection.opacity(0.7) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .onTapGesture { store.selectedFolderID = folder.id }
        .help(folder.exists ? folder.url.path : "Folder not found: \(folder.url.path)")
        .contextMenu {
            Button("Synchronize Folder") { Task { await store.addFolder(folder.url) } }
                .disabled(!folder.exists)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
                .disabled(!folder.exists)
        }
    }
}

// MARK: - Presets

struct PresetsSection: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var hovered: Int64?

    var body: some View {
        PanelSection("Presets", startExpanded: true, accessory: {
            HStack(spacing: 10) {
                if store.isImportingPresets {
                    ProgressView().controlSize(.mini)
                }
                Button {
                    store.chooseAndImportPresets()
                } label: {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Import presets (.xmp, .lrtemplate, .dng, .zip)")
                Button {
                    store.settingsSheet = .savePreset
                } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Save the current settings as a preset")
            }
            .foregroundStyle(Theme.textDim)
        }) {
            if store.presets.isEmpty {
                Text("No presets yet. Click + to save the current settings, or ↓ to import presets.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                PanelButton(title: "Import Presets…") { store.chooseAndImportPresets() }
            } else {
                DevelopSlider(
                    title: "Amount",
                    value: Binding(
                        get: { store.presetAmount },
                        set: { store.previewPresetAmount($0.rounded()) }),
                    range: 0...200,
                    format: { "\(Int($0.rounded()))%" },
                    onReset: {
                        store.previewPresetAmount(100)
                        store.commitPresetAmount()
                    },
                    onEditingChanged: { editing in
                        if !editing { store.commitPresetAmount() }
                    })
                    .help(store.lastAppliedPresetName.map { "Strength of presets you click (and of “\($0)”)" }
                          ?? "Strength of presets you click")
                Text("Hover a preset to preview it on the photo.")
                    .font(Theme.smallFont)
                    .foregroundStyle(Theme.textDim)
            }
            ForEach(store.presets) { preset in
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textDim)
                    Text(preset.name)
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .background(hovered == preset.id ? Theme.selection.opacity(0.45) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
                .onTapGesture { store.applyPreset(preset) }
                .onHover { inside in
                    if inside {
                        hovered = preset.id
                        store.previewPreset(preset)
                    } else if hovered == preset.id {
                        hovered = nil
                        store.previewPreset(nil)
                    }
                }
                .help("Click to apply")
                .contextMenu {
                    Button("Apply") { store.applyPreset(preset) }
                    Button("Delete", role: .destructive) { store.deletePreset(preset) }
                }
            }
        }
    }
}

// MARK: - Collections

struct CollectionsSection: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        PanelSection("Collections", startExpanded: true, accessory: {
            Menu {
                Button("New Collection…") { newCollection(withSelection: false) }
                Button("New Collection from Selection…") { newCollection(withSelection: true) }
                    .disabled(store.selectedPhotoID == nil)
            } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Theme.textDim)
            .help("New collection")
        }) {
            if store.collections.isEmpty {
                Text("Group photos from any folder: right-click photos → Add to Collection, or click +.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(store.collections) { collection in
                row(collection)
            }
        }
    }

    private func newCollection(withSelection: Bool) {
        guard let name = TextPrompt.ask(title: withSelection ? "New Collection from Selection" : "New Collection",
                                        message: "Name:", confirm: "Create") else { return }
        if let id = store.createCollection(named: name, withSelection: withSelection), withSelection {
            store.showCollection(id)
        }
    }

    private func row(_ collection: PhotoCollection) -> some View {
        let selected = collection.id == store.selectedCollectionID
        return HStack(spacing: 6) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
            Text(collection.name)
                .font(Theme.bodyFont)
                .foregroundStyle(selected ? Theme.textBright : Theme.text)
                .lineLimit(1)
            Spacer()
            Text("\(collection.count)")
                .font(Theme.smallFont)
                .foregroundStyle(Theme.textDim)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(selected ? Theme.selection.opacity(0.7) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .onTapGesture { store.showCollection(collection.id) }
        .contextMenu {
            Button("Add Selected Photos") { store.addSelection(toCollection: collection.id) }
                .disabled(store.selectedPhotoID == nil)
            Button("Rename…") {
                if let name = TextPrompt.ask(title: "Rename Collection", defaultValue: collection.name, confirm: "Rename") {
                    store.renameCollection(collection.id, to: name)
                }
            }
            Button("Delete Collection", role: .destructive) { store.deleteCollection(collection.id) }
        }
    }
}

// MARK: - People

struct PeopleSection: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        PanelSection("People", startExpanded: true, accessory: {
            Button {
                store.showPeopleSheet = true
            } label: {
                Image(systemName: "person.2").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textDim)
            .help("Find and name faces")
        }) {
            if store.people.isEmpty {
                Text("Find faces in your photos, name them, then show one person's photos.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                PanelButton(title: "People…") { store.showPeopleSheet = true }
            }
            ForEach(store.people) { person in
                row(person)
            }
        }
    }

    private func row(_ person: Person) -> some View {
        let selected = store.personFilter == person.id
        return HStack(spacing: 6) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
            Text(person.name)
                .font(Theme.bodyFont)
                .foregroundStyle(selected ? Theme.textBright : Theme.text)
                .lineLimit(1)
            Spacer()
            Text("\(person.faceCount)")
                .font(Theme.smallFont)
                .foregroundStyle(Theme.textDim)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(selected ? Theme.selection.opacity(0.7) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .onTapGesture { store.showPerson(selected ? nil : person.id) }
        .help(selected ? "Show everyone again" : "Show only photos of \(person.name)")
        .contextMenu {
            Button("Rename…") {
                if let name = TextPrompt.ask(title: "Rename Person", defaultValue: person.name, confirm: "Rename") {
                    store.renamePerson(person.id, to: name)
                }
            }
            Button("Delete Person", role: .destructive) { store.deletePerson(person.id) }
        }
    }
}

// MARK: - Snapshots

struct SnapshotsSection: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject var session: DevelopSession
    @State private var hovered: Int64?

    var body: some View {
        PanelSection("Snapshots", accessory: {
            Button {
                let suggested = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
                if let name = TextPrompt.ask(title: "New Snapshot", message: "Saves the current settings under a name.",
                                             defaultValue: suggested, confirm: "Save") {
                    store.saveSnapshot(named: name)
                }
            } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textDim)
            .disabled(session.photo == nil)
            .help("Save the current settings as a snapshot")
        }) {
            if store.snapshots.isEmpty {
                Text("Click + to keep a version of this photo's edit you can come back to.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(store.snapshots) { snapshot in
                HStack {
                    Image(systemName: "camera.on.rectangle").font(.system(size: 10)).foregroundStyle(Theme.textDim)
                    Text(snapshot.name).font(Theme.bodyFont).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .background(hovered == snapshot.id ? Theme.selection.opacity(0.45) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
                .onTapGesture { store.applySnapshot(snapshot) }
                .onHover { inside in
                    if inside {
                        hovered = snapshot.id
                        store.previewSnapshot(snapshot)
                    } else if hovered == snapshot.id {
                        hovered = nil
                        store.previewSnapshot(nil)
                    }
                }
                .help("Click to apply (hover to preview)")
                .contextMenu {
                    Button("Apply") { store.applySnapshot(snapshot) }
                    Button("Delete", role: .destructive) { store.deleteSnapshot(snapshot) }
                }
            }
        }
        .task(id: session.photo?.id) { store.reloadSnapshots() }
    }
}

// MARK: - History

struct HistorySection: View {
    @ObservedObject var session: DevelopSession

    var body: some View {
        PanelSection("History", accessory: {
            Button("Clear") { session.clearHistory() }
                .buttonStyle(.plain)
                .font(Theme.smallFont)
                .foregroundStyle(Theme.textDim)
                .disabled(session.history.count <= 1)
                .help("Forget the steps (the current edit stays)")
        }) {
            // Newest at the top, like Lightroom.
            ForEach(Array(session.history.enumerated().reversed()), id: \.element.id) { index, step in
                let current = index == session.historyIndex
                let undone = index > session.historyIndex
                HStack {
                    Text(step.label)
                        .font(Theme.bodyFont)
                        .foregroundStyle(current ? Theme.textBright : (undone ? Theme.textDim.opacity(0.6) : Theme.text))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(current ? Theme.selection.opacity(0.6) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
                .onTapGesture { session.goToStep(index) }
            }
        }
    }
}
