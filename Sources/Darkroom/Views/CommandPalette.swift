import SwiftUI

/// One entry in the command palette (⌘K).
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    /// Extra words it's found by (slider names for panels, etc.).
    var keywords = ""
    var shortcut = ""
    var section: String
    var enabled = true
    let action: @MainActor () -> Void

    fileprivate var haystack: String { (title + " " + keywords + " " + section).lowercased() }
}

/// ⌘K: type a command, panel or slider name, press Return.
struct CommandPalette: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        let results = Self.filter(store.paletteItems(), query: query)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Type a command, panel or slider (e.g. exposure, export, HDR)…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { run(results) }
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == selection)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selection = index
                                    run(results)
                                }
                        }
                        if results.isEmpty {
                            Text("Nothing found").foregroundStyle(.secondary).padding(12)
                        }
                    }
                }
                .onChange(of: selection) { _, value in
                    if results.indices.contains(value) { proxy.scrollTo(results[value].id) }
                }
            }
        }
        .frame(width: 520, height: 420)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selection = 0 }
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, max(results.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0)
            return .handled
        }
        .onExitCommand { store.showCommandPalette = false }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack {
            Text(item.title).foregroundStyle(item.enabled ? .primary : .secondary)
            Text(item.section).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if !item.shortcut.isEmpty {
                Text(item.shortcut).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.25) : Color.clear)
    }

    private func run(_ results: [PaletteItem]) {
        guard results.indices.contains(selection) else { return }
        let item = results[selection]
        guard item.enabled else { return }
        store.showCommandPalette = false
        // After the sheet closes, so commands that open another sheet work.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            item.action()
        }
    }

    /// Every word must appear; titles starting with the query come first.
    static func filter(_ items: [PaletteItem], query: String) -> [PaletteItem] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        let words = q.split(separator: " ")
        return items
            .filter { item in words.allSatisfy { item.haystack.contains($0) } }
            .map { item -> (PaletteItem, Int) in
                let title = item.title.lowercased()
                let rank = title.hasPrefix(q) ? 0 : title.contains(q) ? 1 : 2
                return (item, rank + (item.enabled ? 0 : 3))
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }
}

extension LibraryStore {
    /// Everything the command palette can do, built fresh each time it's shown.
    @MainActor
    func paletteItems() -> [PaletteItem] {
        let hasPhoto = selectedPhotoID != nil
        let inDevelop = viewMode == .develop
        var items: [PaletteItem] = []
        func add(_ title: String, _ section: String, keywords: String = "", shortcut: String = "",
                 enabled: Bool = true, _ action: @escaping @MainActor () -> Void) {
            items.append(PaletteItem(id: section + "/" + title, title: title, keywords: keywords, shortcut: shortcut,
                                     section: section, enabled: enabled, action: action))
        }

        // Views
        add("Grid", "View", keywords: "library thumbnails", shortcut: "G") { _ = self.handle(.grid) }
        add("Loupe", "View", keywords: "single photo", shortcut: "E", enabled: hasPhoto) { _ = self.handle(.loupe) }
        add("Compare", "View", shortcut: "C", enabled: hasPhoto) { _ = self.handle(.compare) }
        add("Survey", "View", keywords: "side by side choose best burst", shortcut: "N",
            enabled: selectedIDs.count > 1) { _ = self.handle(.survey) }
        add(autoSync ? "Turn Auto Sync Off" : "Turn Auto Sync On", "Photo",
            keywords: "sync edits all selected") { self.autoSync.toggle() }
        add("Develop", "View", keywords: "edit", shortcut: "D", enabled: hasPhoto) { _ = self.handle(.develop) }
        add("Full Screen", "View", shortcut: "F") { _ = self.handle(.fullScreen) }
        add("Show / Hide Side Panels", "View", shortcut: "⇥") { _ = self.handle(.togglePanels) }
        add("Solo Mode (one Develop panel open)", "View", keywords: "panels accordion") {
            let defaults = UserDefaults.standard
            defaults.set(!defaults.bool(forKey: PanelSolo.enabledKey), forKey: PanelSolo.enabledKey)
        }

        // Develop panels (and the sliders in them)
        let panels: [(title: String, id: String, keywords: String)] = [
            ("Basic", "Basic", "exposure contrast highlights shadows whites blacks temp tint white balance texture clarity dehaze vibrance saturation profile auto"),
            ("Tone Curve", "Tone Curve", "curve point parametric rgb"),
            ("Color Mixer", "HSL", "hsl hue saturation luminance black white b&w mix"),
            ("Point Color", "Point Color", "point colour"),
            ("Color Grading", "Color Grading", "grade split toning shadows midtones highlights wheels"),
            ("Detail", "Detail", "sharpening sharpen noise reduction denoise luminance color noise"),
            ("Lens Corrections", "Lens", "lens profile chromatic aberration distortion vignetting"),
            ("Lens Blur", "Lens Blur", "bokeh background blur depth"),
            ("Effects", "Effects", "vignette grain post-crop"),
            ("Calibration", "Calibration", "primaries red green blue"),
        ]
        for panel in panels {
            add(panel.title + " Panel", "Develop panel", keywords: panel.keywords, enabled: hasPhoto) {
                if self.viewMode != .develop { self.setViewMode(.develop) }
                self.develop.finishTools()
                PanelSolo.open(panel.id)
            }
        }

        // Develop tools
        add("Crop & Straighten", "Tool", keywords: "rotate angle aspect", shortcut: "R", enabled: hasPhoto) { _ = self.handle(.crop) }
        add("Healing", "Tool", keywords: "spot removal heal clone", shortcut: "Q", enabled: hasPhoto) { _ = self.handle(.healing) }
        add("Masking", "Tool", keywords: "mask brush gradient subject sky", shortcut: "⇧W", enabled: hasPhoto) { _ = self.handle(.masking) }
        add("White Balance Selector", "Tool", keywords: "eyedropper wb", shortcut: "W", enabled: inDevelop) { _ = self.handle(.whiteBalancePicker) }
        add("Before / After", "Tool", shortcut: "\\", enabled: inDevelop) { _ = self.handle(.beforeAfter) }
        add("Show Clipping", "Tool", keywords: "highlights shadows warning", shortcut: "J", enabled: inDevelop) { _ = self.handle(.clipping) }
        add("Zoom", "Tool", keywords: "100% 1:1", shortcut: "Z", enabled: hasPhoto) { _ = self.handle(.zoom) }

        add("Delete Photo…", "Photo", keywords: "remove trash delete catalog", shortcut: "⌫", enabled: hasPhoto) {
            self.confirmDeleteSelected()
        }

        // Auto-Rotate
        add("Auto-Rotate Portraits", "Photo", keywords: "orientation rotate vertical sideways upright portrait",
            enabled: hasPhoto) { self.autoRotateSelected() }
        add(autoRotatePortraits ? "Turn Auto-Rotate on Import Off" : "Turn Auto-Rotate on Import On", "Photo",
            keywords: "orientation rotate vertical portrait") { self.autoRotatePortraits.toggle() }

        // Help
        add("LumaGrader Guide (Features)", "Help", keywords: "tutorial help how to features", shortcut: "⇧⌘/") { self.guideTab = .features }
        add("Mac Security: Open Anyway", "Help", keywords: "gatekeeper blocked verify damaged install") { self.guideTab = .security }
        add("About LumaGrader", "Help", keywords: "version about") { self.guideTab = .about }
        if Support.url != nil {
            add("Support LumaGrader on Ko-fi", "Help", keywords: "donate coffee kofi tip") { Support.open() }
        }

        // Focus Check
        add(focusPeaking ? "Turn Focus Peaking Off" : "Turn Focus Peaking On", "View",
            keywords: "focus check sharp peaking blur", shortcut: "⇧F", enabled: hasPhoto) { self.toggleFocusPeaking() }
        add("Zoom to Sharpest Area", "View", keywords: "focus check sharp eye 100%", shortcut: "⇧Z",
            enabled: hasPhoto) { self.zoomToSharpest() }

        // Tether
        if isTethering {
            add("Stop Tethered Capture", "Library", keywords: "tether camera eos utility hot folder") { self.stopTether() }
        } else {
            add("Start Tethered Capture…", "Library", keywords: "tether camera eos utility hot folder canon") { self.beginTether() }
        }

        // Print
        add("Print Module", "View", keywords: "printer paper page", shortcut: "⌥⌘P", enabled: hasPhoto) { self.setViewMode(.print) }
        add("Print…", "Photo", keywords: "printer paper", shortcut: "⌘P", enabled: hasPhoto) { self.printSelected() }
        add("Page Setup…", "Photo", keywords: "paper size orientation printer", shortcut: "⇧⌘P") { self.pageSetup() }

        // Catalog
        add("Back Up Catalog Now", "Catalog", keywords: "backup save copy safety") { self.backUpCatalogNow() }
        add("Show Catalog Backups", "Catalog", keywords: "backup finder") { self.showBackupsInFinder() }
        add("Restore Catalog from Backup…", "Catalog", keywords: "backup undo recover") { self.restoreCatalog() }

        // Photo
        add("Export…", "Photo", keywords: "save jpeg", shortcut: "⇧⌘E", enabled: hasPhoto) { self.beginExport() }
        add("Export with Previous", "Photo", shortcut: "⌥⇧⌘E", enabled: hasPhoto && !exportQueue.lastOptions.isEmpty) { self.exportWithPrevious() }
        add("Auto Tone", "Photo", keywords: "automatic", shortcut: "⌘U", enabled: hasPhoto) { self.autoSettings(tone: true, whiteBalance: false) }
        add("Auto White Balance", "Photo", keywords: "automatic wb", shortcut: "⇧⌘U", enabled: hasPhoto) { self.autoSettings(tone: false, whiteBalance: true) }
        add("Auto Tone + White Balance", "Photo", shortcut: "⌥⌘U", enabled: hasPhoto) { self.autoSettings(tone: true, whiteBalance: true) }
        add("Copy Settings…", "Photo", shortcut: "⇧⌘C", enabled: hasPhoto) { self.settingsSheet = .copy }
        add("Copy All Settings", "Photo", shortcut: "⌥⌘C", enabled: hasPhoto) { self.copyAllSettings() }
        add("Paste Settings", "Photo", shortcut: "⇧⌘V", enabled: canPaste) { self.pasteSettings() }
        add("Paste Settings from Previous", "Photo", shortcut: "⌥⌘V", enabled: canPasteFromPrevious) { self.pasteFromPrevious() }
        add("Sync Settings…", "Photo", shortcut: "⇧⌘S", enabled: canSync) { self.settingsSheet = .sync }
        add("Reset Settings", "Photo", shortcut: "⇧⌘R", enabled: hasPhoto) { self.resetSettings() }
        add("Convert to Black & White", "Photo", keywords: "monochrome b&w", shortcut: "V", enabled: hasPhoto) { self.toggleBlackWhite() }
        add("Rotate Left", "Photo", shortcut: "⌘[", enabled: hasPhoto) { self.rotate(clockwise: false) }
        add("Rotate Right", "Photo", shortcut: "⌘]", enabled: hasPhoto) { self.rotate(clockwise: true) }
        add("Create Virtual Copy", "Photo", keywords: "duplicate", shortcut: "⌘'", enabled: hasPhoto) { self.createVirtualCopy() }
        add("HDR Merge…", "Photo", keywords: "photo merge bracket", shortcut: "⌃H", enabled: canMergeHDR) { self.beginHDRMerge() }
        add("Save Settings as Preset…", "Photo", enabled: hasPhoto) { self.settingsSheet = .savePreset }
        add("Import Presets…", "Photo", keywords: "xmp lightroom") { self.chooseAndImportPresets() }

        // Library
        add("Import Photos…", "Library", keywords: "card sd copy rename backup", shortcut: "⇧⌘I") { self.beginImport() }
        add("Add Folder Without Copying…", "Library", keywords: "import add photos") {
            if let url = FolderPicker.chooseFolder() { Task { await self.addFolder(url) } }
        }
        add("People…", "Library", keywords: "faces names") { self.showPeopleSheet = true }
        add("Find Faces", "Library", keywords: "people", enabled: faceProgress == nil && !photos.isEmpty) { self.findFaces() }
        add("AI Cull…", "Library", keywords: "sharpness closed eyes best", enabled: !photos.isEmpty) { self.showCullSheet = true }
        add("Clear Filters", "Library", keywords: "show all", enabled: isFiltering) { self.clearFilters() }
        add("Select All", "Library", shortcut: "⌘A") { self.selectAll() }
        add("Select None", "Library", shortcut: "⌘D") { self.selectNone() }
        add("Select Picks", "Library") { self.selectFlagged(.pick) }

        // Flags, ratings, labels
        add("Pick", "Flag", keywords: "flag", shortcut: "P", enabled: hasPhoto) { self.setFlag(.pick) }
        add("Reject", "Flag", keywords: "flag", shortcut: "X", enabled: hasPhoto) { self.setFlag(.reject) }
        add("Unflag", "Flag", shortcut: "U", enabled: hasPhoto) { self.setFlag(.unflagged) }
        for stars in 0...5 {
            add(stars == 0 ? "No Rating" : "Rate \(stars) Star\(stars == 1 ? "" : "s")", "Rating", keywords: "stars",
                shortcut: "\(stars)", enabled: hasPhoto) { self.setRating(stars) }
        }
        for label in ColorLabel.colors {
            add("\(label.name) Label", "Label", keywords: "color colour", shortcut: label.key.map { "\($0)" } ?? "",
                enabled: hasPhoto) { self.setLabel(label) }
        }

        // Presets
        for preset in presets {
            add(preset.name, "Preset", keywords: "apply", enabled: hasPhoto) { self.applyPreset(preset) }
        }
        return items
    }
}
