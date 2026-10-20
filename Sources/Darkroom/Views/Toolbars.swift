import SwiftUI

/// "Library Filter" bar above the grid.
struct LibraryFilterBar: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        HStack(spacing: 14) {
            Text("Library Filter:")
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textDim)
            Picker("Flag", selection: $store.flagFilter) {
                ForEach(LibraryStore.FlagFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Picker("Rating", selection: $store.minRating) {
                Text("Any rating").tag(0)
                ForEach(1...5, id: \.self) { stars in
                    Text(String(repeating: "★", count: stars) + " and up").tag(stars)
                }
            }
            .labelsHidden()
            .fixedSize()
            Picker("Label", selection: $store.labelFilter) {
                ForEach(LibraryStore.LabelFilter.allOptions) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
            .fixedSize()
            if !store.people.isEmpty {
                Picker("Person", selection: $store.personFilter) {
                    Text("Anyone").tag(Int64?.none)
                    ForEach(store.people) { person in
                        Text(person.name).tag(Int64?.some(person.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            TextField("Search", text: $store.searchText, prompt: Text("Search name, title, keywords"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)
            Toggle("Stack RAW + JPEG", isOn: $store.stackRawJpeg)
            Toggle("Auto-advance", isOn: $store.autoAdvance)
                .help("Go to the next photo after P, X or U")
            if !store.analysis.isEmpty {
                Toggle("Best first", isOn: $store.sortByScore)
                    .help("Sort by AI Cull score")
            }
            Spacer()
            if store.isFiltering {
                Button("Clear") { store.clearFilters() }
            }
            Button {
                store.showCullSheet = true
            } label: {
                Label("AI Cull…", systemImage: "sparkles")
            }
            .disabled(store.photos.isEmpty)
            .help("Let the Mac rate sharpness, closed eyes and similar shots, then pick and reject")
        }
        .controlSize(.small)
        .font(Theme.bodyFont)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }
}

/// Toolbar under the photo/grid (Lightroom's "T" toolbar).
struct CenterToolbar: View {
    @EnvironmentObject private var store: LibraryStore
    /// Observed directly so the Develop buttons update with the session.
    @ObservedObject var session: DevelopSession
    @AppStorage("thumbnailSize") private var thumbnailSize: Double = 180

    var body: some View {
        HStack(spacing: 6) {
            if store.isDevelopModule {
                developTools
            } else {
                libraryTools
            }
            Divider().frame(height: 16).padding(.horizontal, 6)
            ratingAndFlags
            Spacer()
            if store.viewMode == .grid {
                Text("Thumbnails").font(Theme.smallFont).foregroundStyle(Theme.textDim)
                Slider(value: $thumbnailSize, in: 120...320)
                    .controlSize(.mini)
                    .frame(width: 110)
            }
        }
        .tint(Theme.control)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }

    private var libraryTools: some View {
        HStack(spacing: 2) {
            ToolbarIconButton(systemImage: "square.grid.3x3", help: "Grid (G)", isOn: store.viewMode == .grid) {
                store.setViewMode(.grid)
            }
            ToolbarIconButton(systemImage: "rectangle", help: "Loupe (E)", isOn: store.viewMode == .loupe) {
                store.setViewMode(.loupe)
            }
            ToolbarIconButton(systemImage: "rectangle.split.2x1", help: "Compare (C)", isOn: store.viewMode == .compare) {
                store.setViewMode(.compare)
            }
            ToolbarIconButton(systemImage: "square.grid.2x2", help: "Survey (N): the selected photos side by side",
                              isOn: store.viewMode == .survey) {
                store.setViewMode(.survey)
            }
            if store.viewMode == .loupe {
                zoomControls
            }
            if [.loupe, .compare, .survey].contains(store.viewMode) {
                ToolbarIconButton(systemImage: "scope", help: "Focus peaking: red = in focus (⇧F)",
                                  isOn: store.focusPeaking) {
                    store.toggleFocusPeaking()
                }
                if store.viewMode == .loupe {
                    ToolbarIconButton(systemImage: "viewfinder", help: "Zoom to Sharpest Area (⇧Z)") {
                        store.zoomToSharpest()
                    }
                }
            }
        }
    }

    private var developTools: some View {
        HStack(spacing: 2) {
            ToolbarIconButton(systemImage: "rectangle", help: "Loupe (E)") { store.setViewMode(.loupe) }
            ToolbarIconButton(systemImage: session.showOriginal ? "eye.slash" : "eye",
                              help: "Before / after (\\)", isOn: session.showOriginal) {
                session.toggleBeforeAfter()
            }
            ToolbarIconButton(systemImage: "rectangle.split.2x1", help: "Before | After side by side (Y)",
                              isOn: session.compareLayout == .sideBySide) {
                session.compareLayout = session.compareLayout == .sideBySide ? .off : .sideBySide
            }
            ToolbarIconButton(systemImage: "square.split.2x1", help: "Before | After split (Y)",
                              isOn: session.compareLayout == .split) {
                session.compareLayout = session.compareLayout == .split ? .off : .split
            }
            ToolbarIconButton(systemImage: "crop", help: "Crop & Straighten (R)", isOn: session.cropMode) {
                session.setCropMode(!session.cropMode)
            }
            if !session.cropMode {
                zoomControls
            }
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            ToolbarIconButton(systemImage: "plus.magnifyingglass", help: "Zoom (Z)", isOn: store.zoom.isZoomed) {
                store.toggleZoom()
            }
            ZoomMenu(zoom: $store.zoom) { store.pickZoom($0) }
                .foregroundStyle(Theme.textDim)
        }
    }

    @ViewBuilder
    private var ratingAndFlags: some View {
        if let photo = store.selectedPhoto {
            HStack(spacing: 2) {
                ToolbarIconButton(systemImage: "flag.fill", help: "Pick (P)", isOn: photo.flag == .pick) {
                    store.setFlag(photo.flag == .pick ? .unflagged : .pick)
                }
                ToolbarIconButton(systemImage: "xmark", help: "Reject (X)", isOn: photo.flag == .reject) {
                    store.setFlag(photo.flag == .reject ? .unflagged : .reject)
                }
                ForEach(1...5, id: \.self) { stars in
                    Button {
                        store.setRating(photo.rating == stars ? 0 : stars)
                    } label: {
                        Image(systemName: stars <= photo.rating ? "star.fill" : "star")
                            .font(.system(size: 11))
                            .foregroundStyle(stars <= photo.rating ? Theme.textBright : Theme.textDim)
                            .frame(width: 16, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(stars) star\(stars == 1 ? "" : "s") (\(stars))")
                }
                Divider().frame(height: 14).padding(.horizontal, 4)
                ForEach(ColorLabel.colors) { label in
                    Button {
                        store.setLabel(label)
                    } label: {
                        LabelSwatch(label: label, isOn: photo.label == label)
                            .frame(width: 16, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(label.key.map { "\(label.name) label (\($0))" } ?? "\(label.name) label")
                }
            }
        }
    }
}
