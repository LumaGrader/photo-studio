import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ExportSheet: View {
    @EnvironmentObject private var store: LibraryStore
    let photos: [Photo]
    let onClose: () -> Void

    /// Which photos to export.
    enum Scope: String, CaseIterable, Identifiable {
        case selected = "Selected"
        case shown = "All shown"
        case picks = "Picks"
        var id: String { rawValue }
    }
    @State private var scope: Scope = .selected
    /// Batch: also export with these saved presets (each into its own folder).
    @State private var batchPresets: Set<String> = []
    @State private var useCurrentSettings = true
    @State private var watermarkPreview: CGImage?

    @AppStorage("export.format") private var formatRaw = ExportFormat.jpeg.rawValue
    @AppStorage("export.quality") private var quality = 0.9
    @AppStorage("export.resize") private var resize = false
    @AppStorage("export.longEdge") private var longEdge = 2048
    @AppStorage("export.folder") private var folderPath = ""
    @AppStorage("export.naming") private var namingRaw = ExportNaming.original.rawValue
    @AppStorage("export.customName") private var customName = ""
    @AppStorage("export.stripLocation") private var stripLocation = false
    @AppStorage("export.watermark") private var watermarkData = Data()
    @State private var watermark = WatermarkSettings()
    @State private var presets = ExportPreset.load()


    private var format: ExportFormat { ExportFormat(rawValue: formatRaw) ?? .jpeg }
    private var naming: ExportNaming { ExportNaming(rawValue: namingRaw) ?? .original }
    private var folder: URL? { folderPath.isEmpty ? nil : URL(fileURLWithPath: folderPath, isDirectory: true) }

    private var scopedPhotos: [Photo] {
        switch scope {
        case .selected: return photos
        case .shown: return store.visiblePhotos
        case .picks: return store.visiblePhotos.filter { $0.flag == .pick }
        }
    }

    private var jobCount: Int {
        scopedPhotos.count * ((useCurrentSettings ? 1 : 0) + batchPresets.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Export").font(.title3.weight(.semibold))
                Picker("Photos", selection: $scope) {
                    ForEach(Scope.allCases) { scope in
                        Text(label(for: scope)).tag(scope)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                presetMenu
            }

            form

            HStack {
                Text(jobCount == 0 ? "Nothing to export."
                     : "\(jobCount) file\(jobCount == 1 ? "" : "s") will be saved\(store.exportQueue.isRunning ? " after the current export" : ""). You can keep working while they export.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Export") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled((useCurrentSettings && folder == nil) || jobCount == 0)
            }
        }
        .padding(20)
        .frame(width: 520, height: 680)
        .onAppear {
            if let saved = try? JSONDecoder().decode(WatermarkSettings.self, from: watermarkData) { watermark = saved }
        }
        .onChange(of: watermark) { _, value in
            if let data = try? JSONEncoder().encode(value) { watermarkData = data }
        }
        .task(id: PreviewKey(watermark: watermark, photoID: scopedPhotos.first?.id)) {
            await renderWatermarkPreview()
        }
    }

    private func label(for scope: Scope) -> String {
        switch scope {
        case .selected: return "Selected (\(photos.count))"
        case .shown: return "All shown (\(store.visiblePhotos.count))"
        case .picks: return "Picks (\(store.visiblePhotos.filter { $0.flag == .pick }.count))"
        }
    }

    private struct PreviewKey: Equatable {
        let watermark: WatermarkSettings
        let photoID: Int64?
    }

    /// Small render of the first photo with the watermark (debounced).
    private func renderWatermarkPreview() async {
        guard watermark.isUsable, let photo = scopedPhotos.first ?? photos.first else {
            watermarkPreview = nil
            return
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        if Task.isCancelled { return }
        let settings = watermark
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = DevelopRenderer.makeSource(url: photo.url, maxPixel: 900),
                  var output = DevelopRenderer.apply(photo.develop, to: source, cube: ToneCubeCache()) else { return nil }
            output = WatermarkRenderer.apply(settings, to: output)
            return DevelopRenderer.context.createCGImage(output, from: output.extent.integral,
                                                         format: .RGBA8, colorSpace: DevelopRenderer.sRGB)
        }.value
        if !Task.isCancelled { watermarkPreview = image }
    }

    // MARK: - Presets

    private var presetMenu: some View {
        Menu("Presets") {
            ForEach(presets) { preset in
                Button(preset.name) { apply(preset) }
            }
            if !presets.isEmpty { Divider() }
            Button("Save Current Settings…") {
                if let name = TextPrompt.ask(title: "Save Export Preset", message: "Name:", confirm: "Save") {
                    var list = presets.filter { $0.name != name }
                    list.append(currentPreset(named: name))
                    ExportPreset.save(list)
                    presets = ExportPreset.load()
                }
            }
            if !presets.isEmpty {
                Menu("Delete") {
                    ForEach(presets) { preset in
                        Button(preset.name, role: .destructive) {
                            ExportPreset.save(presets.filter { $0.name != preset.name })
                            presets = ExportPreset.load()
                        }
                    }
                }
            }
        }
        .fixedSize()
    }

    private func currentPreset(named name: String) -> ExportPreset {
        ExportPreset(name: name, format: formatRaw, quality: quality, resize: resize, longEdge: longEdge,
                     folderPath: folderPath, naming: namingRaw, customName: customName,
                     stripLocation: stripLocation, watermark: watermark)
    }

    private func apply(_ p: ExportPreset) {
        formatRaw = p.format
        quality = p.quality
        resize = p.resize
        longEdge = p.longEdge
        if !p.folderPath.isEmpty { folderPath = p.folderPath }
        namingRaw = p.naming
        customName = p.customName
        stripLocation = p.stripLocation
        watermark = p.watermark
    }

    private var form: some View {
        Form {
            if !presets.isEmpty {
                Section {
                    Toggle("These settings (below)", isOn: $useCurrentSettings)
                    ForEach(presets) { preset in
                        Toggle(isOn: Binding(
                            get: { batchPresets.contains(preset.name) },
                            set: { on in
                                if on { batchPresets.insert(preset.name) } else { batchPresets.remove(preset.name) }
                            })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(preset.name)
                                Text(summary(of: preset)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Export with")
                } footer: {
                    Text("Tick several to export each photo in several versions at once (e.g. full size + Instagram). A preset without its own folder saves into a sub-folder named after it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Text(folder?.path ?? "Choose a folder…")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(folder == nil ? Color.secondary : Color.primary)
                    Spacer()
                    Button("Choose…") {
                        if let url = FolderPicker.chooseFolder(prompt: "Choose", message: "Where should exported photos go?") {
                            folderPath = url.path
                        }
                    }
                }
            } header: {
                Text("Save to")
            }

            Section {
                Picker("Format", selection: $formatRaw) {
                    ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                if format == .jpeg {
                    HStack {
                        Slider(value: $quality, in: 0.5...1) { Text("Quality") }
                        Text("\(Int((quality * 100).rounded()))").monospacedDigit().frame(width: 32)
                    }
                }
                Toggle("Resize long edge", isOn: $resize)
                if resize {
                    HStack {
                        TextField("Long edge", value: $longEdge, format: .number)
                            .frame(width: 90)
                        Text("pixels").foregroundStyle(.secondary)
                        Spacer()
                        Menu("Presets") {
                            ForEach([1080, 2048, 3000, 4096], id: \.self) { size in
                                Button("\(size) px") { longEdge = size }
                            }
                        }
                        .fixedSize()
                    }
                }
            } header: {
                Text("File")
            }

            Section {
                Picker("Name", selection: $namingRaw) {
                    ForEach(ExportNaming.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                if naming == .custom {
                    TextField("Name", text: $customName, prompt: Text("e.g. Wedding"))
                }
                Text("Example: \(exampleName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Remove location (GPS)", isOn: $stripLocation)
            } header: {
                Text("Naming & metadata")
            }

            Section {
                Toggle("Add watermark", isOn: $watermark.enabled)
                if watermark.enabled {
                    Picker("Type", selection: $watermark.kind) {
                        ForEach(WatermarkSettings.Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if watermark.kind == .text {
                        TextField("Text", text: $watermark.text)
                    } else {
                        HStack {
                            Text(watermark.imagePath.isEmpty ? "Choose a PNG logo…"
                                 : URL(fileURLWithPath: watermark.imagePath).lastPathComponent)
                                .lineLimit(1)
                                .foregroundStyle(watermark.imagePath.isEmpty ? Color.secondary : Color.primary)
                            Spacer()
                            Button("Choose…") { chooseLogo() }
                        }
                    }
                    Picker("Position", selection: $watermark.position) {
                        ForEach(WatermarkSettings.Position.allCases) { Text($0.rawValue).tag($0) }
                    }
                    HStack {
                        Slider(value: $watermark.size, in: 3...50) { Text("Size") }
                        Text("\(Int(watermark.size))%").monospacedDigit().frame(width: 40)
                    }
                    HStack {
                        Slider(value: $watermark.opacity, in: 10...100) { Text("Opacity") }
                        Text("\(Int(watermark.opacity))%").monospacedDigit().frame(width: 40)
                    }
                    HStack {
                        Slider(value: $watermark.margin, in: 0...10) { Text("Margin") }
                        Text("\(Int(watermark.margin))%").monospacedDigit().frame(width: 40)
                    }
                    watermarkPreviewView
                }
            } header: {
                Text("Watermark")
            }
        }
        .formStyle(.grouped)
    }

    private var exampleName: String {
        guard let first = photos.first else { return "" }
        let options = currentOptions(folder: URL(fileURLWithPath: "/"))
        return Exporter.baseName(for: first, number: 1, options: options) + "." + format.fileExtension
    }

    private func currentOptions(folder: URL) -> ExportOptions {
        ExportOptions(
            format: format,
            quality: quality,
            longEdge: resize ? max(64, min(longEdge, 20000)) : nil,
            folder: folder,
            naming: naming,
            customName: customName,
            stripLocation: stripLocation,
            watermark: watermark)
    }

    @ViewBuilder
    private var watermarkPreviewView: some View {
        HStack {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.35))
                if let watermarkPreview {
                    Image(decorative: watermarkPreview, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else if watermark.isUsable {
                    ProgressView().controlSize(.small)
                } else {
                    Text(watermark.kind == .text ? "Type some text" : "Choose a logo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 200)
            .frame(maxWidth: 320)
            Spacer()
        }
        .help("Preview on the first photo")
    }

    private func summary(of p: ExportPreset) -> String {
        var parts = [p.format.replacingOccurrences(of: " (16-bit)", with: "")]
        parts.append(p.resize ? "\(p.longEdge) px" : "full size")
        if p.watermark.isUsable { parts.append("watermark") }
        parts.append(p.folderPath.isEmpty ? "→ sub-folder" : "→ " + URL(fileURLWithPath: p.folderPath).lastPathComponent)
        return parts.joined(separator: " · ")
    }

    private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a logo (PNG with transparency works best, e.g. a white logo)"
        if panel.runModal() == .OK, let url = panel.url {
            watermark.imagePath = url.path
            watermark.kind = .image
        }
    }

    /// Queues the export (current settings and/or the ticked presets) and closes the sheet.
    private func start() {
        let list = scopedPhotos
        var jobs: [ExportQueue.Job] = []
        if useCurrentSettings, let folder {
            let options = currentOptions(folder: folder)
            jobs += list.enumerated().map { ExportQueue.Job(photo: $0.element, number: $0.offset + 1, options: options) }
        }
        for preset in presets where batchPresets.contains(preset.name) {
            let fallback = folder?.appendingPathComponent(Exporter.sanitized(preset.name), isDirectory: true)
            guard let options = preset.options(defaultFolder: fallback) else { continue }
            try? FileManager.default.createDirectory(at: options.folder, withIntermediateDirectories: true)
            jobs += list.enumerated().map { ExportQueue.Job(photo: $0.element, number: $0.offset + 1, options: options) }
        }
        guard !jobs.isEmpty else { return }
        store.exportQueue.start(jobs)
        onClose()
    }
}
