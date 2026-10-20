import SwiftUI

/// Histogram on top; Library shows Metadata below it, Develop shows the edit panels.
struct RightPanel: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if store.isPrintModule {
                    PrintPanels(model: store.printModel)
                } else {
                    HistogramSection(session: store.develop)
                    if store.isDevelopModule {
                        DevelopPanels(session: store.develop, cropTool: store.cropTool)
                    } else {
                        MetadataSection()
                    }
                }
            }
        }
        .background(Theme.panel)
    }
}

// MARK: - Histogram

struct HistogramSection: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject var session: DevelopSession
    @State private var data: HistogramData?
    @State private var metadata: PhotoMetadata?

    private struct Key: Equatable {
        let develop: Bool
        let image: ObjectIdentifier?
        let photo: Int64?
        let settings: DevelopSettings?
    }

    var body: some View {
        PanelSection("Histogram", startExpanded: true) {
            HistogramView(data: data)
            Text(exposureLine)
                .font(Theme.smallFont)
                .foregroundStyle(Theme.textDim)
                .frame(maxWidth: .infinity)
        }
        .task(id: Key(
            develop: store.isDevelopModule,
            image: store.isDevelopModule ? session.image.map { ObjectIdentifier($0) } : nil,
            photo: store.selectedPhotoID,
            settings: store.isDevelopModule ? nil : store.selectedPhoto?.develop)
        ) {
            await refresh()
        }
    }

    private var exposureLine: String {
        let line = metadata?.exposureLine ?? ""
        return line.isEmpty ? " " : line
    }

    private func refresh() async {
        guard let photo = store.selectedPhoto else {
            data = nil
            metadata = nil
            return
        }
        metadata = await MetadataCache.shared.metadata(for: photo.url)
        let source: CGImage?
        if store.isDevelopModule {
            source = session.image
        } else {
            source = await ImageLoader.shared.displayImage(for: photo, maxPixel: ThumbnailDiskCache.maxPixel)
        }
        guard let source, !Task.isCancelled else { return }
        let computed = await Task.detached(priority: .utility) { HistogramData.compute(source) }.value
        if !Task.isCancelled { data = computed }
    }
}

// MARK: - Metadata (Library)

struct MetadataSection: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var metadata: PhotoMetadata?

    var body: some View {
        PanelSection("Metadata") {
            if let photo = store.selectedPhoto {
                editableFields
                Divider().padding(.vertical, 2)
                row("File", photo.fileName)
                row("Folder", photo.url.deletingLastPathComponent().lastPathComponent)
                row("Rating", photo.rating == 0 ? "–" : String(repeating: "★", count: photo.rating))
                row("Flag", photo.flag == .pick ? "Pick" : photo.flag == .reject ? "Rejected" : "–")
                row("Label", photo.label == .none ? "–" : photo.label.name)
                let names = store.peopleNames(for: photo)
                if !names.isEmpty {
                    row("People", names.joined(separator: ", "))
                }
                if let metadata {
                    ForEach(metadata.rows) { item in
                        row(item.label, item.value)
                    }
                }
            } else {
                Text("No photo selected").font(Theme.bodyFont).foregroundStyle(Theme.textDim)
            }
        }
        .task(id: store.selectedPhoto?.url) {
            guard let url = store.selectedPhoto?.url else {
                metadata = nil
                return
            }
            metadata = await MetadataCache.shared.metadata(for: url)
        }
    }

    /// Title, caption, creator, copyright, keywords — for every selected photo.
    @ViewBuilder
    private var editableFields: some View {
        let targets = store.metadataTargets
        let ids = targets.map(\.id)
        if targets.count > 1 {
            Text("Editing \(targets.count) photos")
                .font(Theme.smallFont)
                .foregroundStyle(Theme.textDim)
        }
        Group {
            field("Title", targets, ids, \.title)
            field("Caption", targets, ids, \.caption, multiline: true)
            field("Creator", targets, ids, \.creator)
            field("Copyright", targets, ids, \.copyright)
            let keywordSets = Set(targets.map { $0.meta.keywords })
            MetaField(
                label: "Keywords",
                value: keywordSets.count == 1 ? (targets.first?.meta.keywords.joined(separator: ", ") ?? "") : "",
                mixed: keywordSets.count > 1,
                multiline: true,
                onCommit: { text in
                    let words = PhotoMeta.keywords(from: text)
                    store.updateMeta(ids: ids) { $0.keywords = words }
                })
        }
        .id(ids)
    }

    private func field(_ label: String, _ targets: [Photo], _ ids: [Int64],
                       _ path: WritableKeyPath<PhotoMeta, String>, multiline: Bool = false) -> some View {
        let values = Set(targets.map { $0.meta[keyPath: path] })
        return MetaField(
            label: label,
            value: values.count == 1 ? (values.first ?? "") : "",
            mixed: values.count > 1,
            multiline: multiline,
            onCommit: { text in
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                store.updateMeta(ids: ids) { $0[keyPath: path] = cleaned }
            })
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(Theme.textDim)
                .frame(width: 78, alignment: .trailing)
            Text(value)
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(Theme.bodyFont)
    }
}

/// One editable metadata line: saves on Return or when you click elsewhere.
private struct MetaField: View {
    let label: String
    let value: String
    let mixed: Bool
    var multiline = false
    let onCommit: (String) -> Void

    @State private var draft = ""
    @State private var edited = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(Theme.textDim)
                .frame(width: 78, alignment: .trailing)
            TextField("", text: Binding(get: { draft }, set: { draft = $0; edited = true }),
                      prompt: Text(mixed ? "Mixed" : "Add \(label.lowercased())"),
                      axis: multiline ? .vertical : .horizontal)
                .textFieldStyle(.plain)
                .lineLimit(multiline ? 1...4 : 1...1)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
        }
        .font(Theme.bodyFont)
        .onAppear { draft = value }
        .onChange(of: value) { _, newValue in
            if !focused { draft = newValue }
        }
        .onDisappear(perform: commit)
    }

    private func commit() {
        guard edited else { return }
        edited = false
        onCommit(draft)
    }
}
