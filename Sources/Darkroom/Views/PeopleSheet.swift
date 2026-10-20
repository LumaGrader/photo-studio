import SwiftUI
import AppKit

/// People window: name groups of similar faces, manage named people.
struct PeopleSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var faces: [FaceRecord] = []
    @State private var groups: [FaceGrouping.Group] = []
    @State private var isGrouping = false
    /// Largest feature-print distance counted as the same person.
    @AppStorage("people.threshold") private var threshold = 0.6
    @State private var names: [Int64: String] = [:]
    @State private var showAllGroups = false

    private static let shownGroups = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    namedSection
                    unnamedSection
                }
                .padding(.vertical, 4)
            }
            HStack {
                Text("Grouping uses the Mac's general image matching, not true face recognition, so check each group before naming it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { store.showPeopleSheet = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 860, height: 640)
        .task(id: store.facesVersion) { await reload() }
        .onChange(of: threshold) { _, _ in Task { await regroup() } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Label("People", systemImage: "person.2").font(.title3.weight(.semibold))
            Spacer()
            if let progress = store.faceProgress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 120)
                Text("\(progress.done) of \(progress.total)").font(.callout).foregroundStyle(.secondary)
                Button("Stop") { store.cancelFaceScan() }
            } else {
                let count = store.photosToScanForFaces.count
                Button(count > 0 ? "Find Faces in \(count) Photos" : "All Photos Searched") { store.findFaces() }
                    .disabled(count == 0)
                    .help("Searches the photos shown in the grid (on-device)")
            }
            Divider().frame(height: 18)
            Text("Grouping").font(.callout).foregroundStyle(.secondary)
            Slider(value: $threshold, in: 0.3...1.0)
                .frame(width: 120)
                .help("Left: stricter groups (fewer mistakes, more groups). Right: looser groups.")
        }
    }

    // MARK: - Named

    @ViewBuilder
    private var namedSection: some View {
        if !store.people.isEmpty {
            Text("Named").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(store.people) { person in
                    personCard(person)
                }
            }
        }
    }

    private func personCard(_ person: Person) -> some View {
        let face = faces.first { $0.personID == person.id }
        return HStack(spacing: 8) {
            FaceThumb(face: face, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(person.name).lineLimit(1)
                Text("\(person.faceCount) face\(person.faceCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(Color.white.opacity(store.personFilter == person.id ? 0.16 : 0.06), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            store.showPerson(person.id)
            store.showPeopleSheet = false
        }
        .help("Show photos of \(person.name)")
        .contextMenu {
            Button("Show Photos") {
                store.showPerson(person.id)
                store.showPeopleSheet = false
            }
            Button("Rename…") {
                if let name = TextPrompt.ask(title: "Rename Person", defaultValue: person.name, confirm: "Rename") {
                    store.renamePerson(person.id, to: name)
                }
            }
            Button("Delete Person", role: .destructive) { store.deletePerson(person.id) }
        }
    }

    // MARK: - Unnamed

    @ViewBuilder
    private var unnamedSection: some View {
        let unnamedCount = groups.reduce(0) { $0 + $1.faces.count }
        HStack {
            Text("Unnamed").font(.headline)
            if unnamedCount > 0 {
                Text("\(unnamedCount) faces in \(groups.count) groups").font(.callout).foregroundStyle(.secondary)
            }
            if isGrouping { ProgressView().controlSize(.small) }
        }
        if groups.isEmpty && !isGrouping {
            Text(faces.isEmpty
                 ? "No faces yet. Click \"Find Faces\" to search the photos shown in the grid."
                 : "Every face has a name. 🎉")
                .foregroundStyle(.secondary)
        }
        let visible = showAllGroups ? groups : Array(groups.prefix(Self.shownGroups))
        ForEach(visible) { group in
            groupRow(group)
        }
        if !showAllGroups && groups.count > Self.shownGroups {
            Button("Show \(groups.count - Self.shownGroups) More Groups") { showAllGroups = true }
        }
    }

    private func groupRow(_ group: FaceGrouping.Group) -> some View {
        let ids = group.faces.map(\.id)
        return VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(group.faces.prefix(24)) { face in
                        FaceThumb(face: face, size: 64)
                            .contextMenu {
                                Button("Not a Face / Ignore") { store.ignoreFaces([face.id]) }
                                Button("Show Photo") { showPhoto(of: face) }
                            }
                            .help("Right-click: ignore this face or show its photo")
                    }
                    if group.faces.count > 24 {
                        Text("+\(group.faces.count - 24)").foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                if let suggestion = group.suggestion {
                    Text("Is this \(suggestion.name)?").foregroundStyle(.secondary)
                    Button("Yes") { store.nameFaces(ids, as: suggestion.name) }
                }
                TextField("Who is this?", text: Binding(
                    get: { names[group.id] ?? "" },
                    set: { names[group.id] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit { name(group) }
                Button("Name") { name(group) }
                    .disabled((names[group.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                if !store.people.isEmpty {
                    Menu("Existing") {
                        ForEach(store.people) { person in
                            Button(person.name) { store.nameFaces(ids, as: person.name) }
                        }
                    }
                    .fixedSize()
                }
                Spacer()
                Button("Ignore Group") { store.ignoreFaces(ids) }
                    .help("These aren't faces, or you don't want to name them")
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    private func name(_ group: FaceGrouping.Group) {
        let name = names[group.id] ?? ""
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.nameFaces(group.faces.map(\.id), as: name)
        names[group.id] = nil
    }

    private func showPhoto(of face: FaceRecord) {
        guard store.photos.contains(where: { $0.id == face.photoID }) else { return }
        store.select(face.photoID)
        store.showPeopleSheet = false
    }

    // MARK: - Loading

    private func reload() async {
        faces = store.loadFaces()
        await regroup()
    }

    private func regroup() async {
        isGrouping = true
        let faces = self.faces, people = store.people, limit = Float(threshold)
        let result = await Task.detached(priority: .userInitiated) {
            FaceGrouping.groups(faces: faces, people: people, threshold: limit)
        }.value
        groups = result
        isGrouping = false
    }
}

/// A face thumbnail from the catalog.
struct FaceThumb: View {
    let face: FaceRecord?
    let size: CGFloat

    var body: some View {
        Group {
            if let data = face?.thumb, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().interpolation(.medium)
            } else {
                Image(systemName: "person.crop.square").resizable().foregroundStyle(.secondary).padding(size * 0.2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
