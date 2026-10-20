import Foundation

/// Import from a card: copy, rename, back up, then add to the catalog.
extension LibraryStore {
    /// Remembered import settings.
    enum ImportDefaults {
        static let base = "import.baseFolder"
        static let backup = "import.backupFolder"
        static let rename = "import.rename"
        static let eject = "import.eject"
        static let creator = "import.creator"
        static let copyright = "import.copyright"
    }

    func beginImport() {
        showImportSheet = true
    }

    /// Lists the photo files in the source (off the main thread).
    func scanImportSource(_ source: URL) async -> [ScannedFile] {
        (try? await Task.detached(priority: .userInitiated) { try FolderScanner.scan(source) }.value) ?? []
    }

    func importedSignatures() -> Set<String> {
        (try? catalog?.importedSignatures()) ?? []
    }

    /// Copies the plan, then adds the shoot folder to the catalog, applies the preset and
    /// metadata, and shows it. Progress in the top bar; Stop cancels after the current file.
    func runImport(_ plan: CardImporter.Plan, options: ImportOptions, source: URL) {
        guard importTask == nil, !plan.items.isEmpty else { return }
        importProgress = BatchProgress(label: "Importing", done: 0, total: plan.items.count)
        let flag = CancelFlag()
        importCancel = flag
        importTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                CardImporter.run(plan, isCancelled: { flag.isCancelled }) { done in
                    Task { @MainActor in self?.importProgress?.done = done }
                }
            }.value
            guard let self else { return }
            self.importProgress = nil
            self.importTask = nil
            self.importCancel = nil
            await self.finishImport(result, options: options, source: source)
        }
    }

    func cancelImport() {
        importCancel?.cancel()
    }

    @MainActor
    private func finishImport(_ result: CardImporter.Result, options: ImportOptions, source: URL) async {
        try? catalog?.recordImported(result.signatures)
        if !result.copied.isEmpty {
            await addFolder(result.folder)
            let paths = Set(result.copied.map(\.path))
            let ids = photos.filter { paths.contains($0.url.path) }.map(\.id)
            applyImportSettings(to: ids, options: options)
        }
        if options.ejectWhenDone, result.failed.isEmpty, !result.copied.isEmpty {
            CardImporter.eject(source)
        }
        var lines = ["Copied \(result.copied.count) photo\(result.copied.count == 1 ? "" : "s") to \(result.folder.path)."]
        if !result.failed.isEmpty {
            lines.append("Couldn't copy \(result.failed.count): \(result.failed.prefix(5).joined(separator: ", "))\(result.failed.count > 5 ? "…" : "").")
        }
        if options.backupFolder != nil {
            lines.append(result.backupFailed.isEmpty
                         ? "Backup copy made."
                         : "Backup failed for \(result.backupFailed.count) file\(result.backupFailed.count == 1 ? "" : "s") — check the backup drive.")
        }
        notice = ("Import", lines.joined(separator: "\n"))
    }

    private func applyImportSettings(to ids: [Int64], options: ImportOptions) {
        let keywords = PhotoMeta.keywords(from: options.keywords)
        let creator = options.creator.trimmingCharacters(in: .whitespaces)
        let copyright = options.copyright.trimmingCharacters(in: .whitespaces)
        if !creator.isEmpty || !copyright.isEmpty || !keywords.isEmpty {
            updateMeta(ids: ids) { meta in
                if !creator.isEmpty { meta.creator = creator }
                if !copyright.isEmpty { meta.copyright = copyright }
                if !keywords.isEmpty {
                    meta.keywords = meta.keywords + keywords.filter { k in
                        !meta.keywords.contains { $0.lowercased() == k.lowercased() }
                    }
                }
            }
        }
        guard let presetID = options.presetID, let preset = presets.first(where: { $0.id == presetID }),
              let catalog else { return }
        for photo in photos where ids.contains(photo.id) {
            let groups = Self.groups(preset.groups, from: preset.settings, for: photo)
            let settings = photo.develop.merging(preset.settings, groups: groups)
            guard settings != photo.develop else { continue }
            do {
                try catalog.setDevelop(settings, photoID: photo.id)
                updatePhotos([photo.id]) { $0.develop = settings }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
    }
}

/// Thread-safe stop flag for background copies.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
