import SwiftUI
import AppKit

/// Import: from a camera card (or any folder) into a folder per shoot, renamed
/// Date_Shoot_0001, with an optional backup copy on another drive.
struct ImportSheet: View {
    @EnvironmentObject private var store: LibraryStore

    @State private var sources: [CardImporter.Source] = []
    @State private var source: CardImporter.Source?
    @State private var files: [ScannedFile] = []
    @State private var scanning = false
    @State private var alreadyImported: Set<String> = []
    @State private var options = ImportOptions(baseFolder: ImportSheet.defaultBase())

    private static func defaultBase() -> URL {
        if let path = UserDefaults.standard.string(forKey: LibraryStore.ImportDefaults.base) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    private var plan: CardImporter.Plan {
        CardImporter.plan(files: files, options: options, alreadyImported: alreadyImported)
    }

    var body: some View {
        let plan = self.plan
        VStack(alignment: .leading, spacing: 14) {
            Label("Import Photos", systemImage: "sdcard").font(.title3.weight(.semibold))

            sourceSection(plan)
            Divider()
            destinationSection(plan)
            Divider()
            extrasSection

            HStack {
                Button("Add a Folder Without Copying…") {
                    store.showImportSheet = false
                    if let url = FolderPicker.chooseFolder() { Task { await store.addFolder(url) } }
                }
                .help("Use photos where they already are (no copy, no rename)")
                Spacer()
                Button("Cancel") { store.showImportSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button(plan.items.isEmpty ? "Import" : "Import \(plan.items.count)") { startImport(plan) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.items.isEmpty || scanning || store.importTask != nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            options.rename = UserDefaults.standard.object(forKey: LibraryStore.ImportDefaults.rename) as? Bool ?? true
            options.ejectWhenDone = UserDefaults.standard.bool(forKey: LibraryStore.ImportDefaults.eject)
            options.creator = UserDefaults.standard.string(forKey: LibraryStore.ImportDefaults.creator) ?? ""
            options.copyright = UserDefaults.standard.string(forKey: LibraryStore.ImportDefaults.copyright) ?? ""
            if let path = UserDefaults.standard.string(forKey: LibraryStore.ImportDefaults.backup) {
                options.backupFolder = URL(fileURLWithPath: path, isDirectory: true)
            }
            alreadyImported = store.importedSignatures()
            refreshSources()
        }
    }

    // MARK: - Source

    private func sourceSection(_ plan: CardImporter.Plan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("From").font(.headline)
                Spacer()
                Button {
                    refreshSources()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Look for cards again")
                Button("Other Folder…") {
                    if let url = FolderPicker.chooseFolder(prompt: "Choose", message: "Choose a folder to import from (it will be copied).") {
                        select(CardImporter.Source(url: url, name: url.lastPathComponent, isCard: false))
                    }
                }
            }
            if sources.isEmpty && source == nil {
                Text("No camera card found. Insert a card (it needs a DCIM folder) or choose another folder.")
                    .foregroundStyle(.secondary)
            }
            Picker("Source", selection: Binding(get: { source }, set: { if let s = $0 { select(s) } })) {
                ForEach(allSources) { s in
                    Label(s.name, systemImage: s.isCard ? "sdcard" : "folder").tag(Optional(s))
                }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            if scanning {
                HStack { ProgressView().controlSize(.small); Text("Reading the card…").foregroundStyle(.secondary) }
            } else if source != nil {
                Text(summary(plan)).font(.callout).foregroundStyle(.secondary)
                Toggle("Skip photos imported before", isOn: $options.skipDuplicates)
            }
        }
    }

    private var allSources: [CardImporter.Source] {
        var list = sources
        if let source, !list.contains(source) { list.append(source) }
        return list
    }

    private func summary(_ plan: CardImporter.Plan) -> String {
        guard !files.isEmpty else { return "No photos here." }
        var text = "\(plan.items.count) photo\(plan.items.count == 1 ? "" : "s") to import"
        text += " · " + ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file)
        if let range = plan.dateRange {
            let a = CardImporter.dayFormat.string(from: range.0), b = CardImporter.dayFormat.string(from: range.1)
            text += " · " + (a == b ? a : "\(a) – \(b)")
        }
        if plan.skipped > 0 { text += " · \(plan.skipped) already imported (skipped)" }
        return text
    }

    // MARK: - Destination

    private func destinationSection(_ plan: CardImporter.Plan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("To").font(.headline)
            HStack {
                Text("Shoot name")
                TextField("e.g. Game vs Tigers", text: $options.shootName)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Main folder")
                Text(options.baseFolder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer()
                Button("Change…") {
                    if let url = FolderPicker.chooseFolder(prompt: "Choose", message: "Where your shoots are kept (a year folder is made inside).") {
                        options.baseFolder = url
                        UserDefaults.standard.set(url.path, forKey: LibraryStore.ImportDefaults.base)
                    }
                }
            }
            Text("→ \(plan.folder.path)").font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.head)
            Toggle("Rename files", isOn: Binding(get: { options.rename }, set: {
                options.rename = $0
                UserDefaults.standard.set($0, forKey: LibraryStore.ImportDefaults.rename)
            }))
            if let first = plan.items.first {
                Text("e.g. \(first.destinationName)").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Toggle("Backup copy to", isOn: Binding(get: { options.backupFolder != nil }, set: { on in
                    if on {
                        chooseBackup()
                    } else {
                        options.backupFolder = nil
                        UserDefaults.standard.removeObject(forKey: LibraryStore.ImportDefaults.backup)
                    }
                }))
                if let backup = options.backupFolder {
                    Text(backup.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    Button("Change…") { chooseBackup() }
                }
            }
            if let backup = options.backupFolder, !FileManager.default.fileExists(atPath: backup.path) {
                Text("The backup drive isn't connected.").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func chooseBackup() {
        if let url = FolderPicker.chooseFolder(prompt: "Choose", message: "Choose a folder on another drive for the backup copy.") {
            options.backupFolder = url
            UserDefaults.standard.set(url.path, forKey: LibraryStore.ImportDefaults.backup)
        }
    }

    // MARK: - Extras

    private var extrasSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apply").font(.headline)
            Picker("Develop preset", selection: $options.presetID) {
                Text("None").tag(Int64?.none)
                ForEach(store.presets) { preset in
                    Text(preset.name).tag(Int64?.some(preset.id))
                }
            }
            HStack {
                TextField("Creator", text: $options.creator).textFieldStyle(.roundedBorder)
                TextField("Copyright", text: $options.copyright).textFieldStyle(.roundedBorder)
            }
            TextField("Keywords (comma separated)", text: $options.keywords).textFieldStyle(.roundedBorder)
            if source?.isCard ?? false {
                Toggle("Eject the card when done", isOn: $options.ejectWhenDone)
            }
        }
    }

    // MARK: - Actions

    private func refreshSources() {
        sources = CardImporter.cards()
        if source == nil, let first = sources.first { select(first) }
    }

    private func select(_ newSource: CardImporter.Source) {
        source = newSource
        files = []
        scanning = true
        Task {
            let found = await store.scanImportSource(newSource.url)
            guard source == newSource else { return }
            files = found
            scanning = false
        }
    }

    private func startImport(_ plan: CardImporter.Plan) {
        guard let source else { return }
        let defaults = UserDefaults.standard
        defaults.set(options.ejectWhenDone, forKey: LibraryStore.ImportDefaults.eject)
        defaults.set(options.creator, forKey: LibraryStore.ImportDefaults.creator)
        defaults.set(options.copyright, forKey: LibraryStore.ImportDefaults.copyright)
        store.runImport(plan, options: options, source: source.url)
        store.showImportSheet = false
    }
}
