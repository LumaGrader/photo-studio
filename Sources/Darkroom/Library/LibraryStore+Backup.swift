import AppKit

/// Catalog backups: daily automatic copy, Back Up Now, choose folder, restore.
extension LibraryStore {
    /// A few seconds after launch, so it doesn't compete with the first thumbnails.
    func scheduleAutoBackup() {
        guard let url = catalogURL, CatalogBackup.isDue else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) { [weak self] in
            guard CatalogBackup.runAutoIfDue(catalog: url) != nil else { return }
            DispatchQueue.main.async { self?.flashBackupStatus("Catalog backed up") }
        }
    }

    @MainActor
    func backUpCatalogNow() {
        guard let url = catalogURL, !isBackingUp else { return }
        isBackingUp = true
        let folder = CatalogBackup.folder
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try CatalogBackup.run(catalog: url, to: folder) }
            }.value
            isBackingUp = false
            switch result {
            case .success:
                flashBackupStatus("Catalog backed up")
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    func chooseBackupFolder() {
        let message = "Choose where catalog backups go. Another drive is safest. The newest \(CatalogBackup.keep) are kept."
        guard let url = FolderPicker.chooseFolder(prompt: "Use Folder", message: message) else { return }
        CatalogBackup.folder = url.appendingPathComponent("LumaGrader Catalog Backups", isDirectory: true)
        backUpCatalogNow()
    }

    @MainActor
    func showBackupsInFinder() {
        let folder = CatalogBackup.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let newest = CatalogBackup.list(in: folder).first {
            NSWorkspace.shared.activateFileViewerSelecting([newest])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    /// Pick a backup, confirm, then quit and reopen with it.
    @MainActor
    func restoreCatalog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = CatalogBackup.folder
        panel.prompt = "Restore"
        panel.message = "Choose a catalog backup (Catalog yyyy-MM-dd ….sqlite)."
        guard panel.runModal() == .OK, let backup = panel.url else { return }

        do {
            try CatalogBackup.check(backup)
        } catch {
            errorMessage = "That file isn't a usable catalog backup. \(error.localizedDescription)"
            return
        }

        let alert = NSAlert()
        alert.messageText = "Restore \(backup.deletingPathExtension().lastPathComponent)?"
        alert.informativeText = """
        LumaGrader will quit and reopen with this backup. Ratings, labels, edits, collections \
        and people made after it will be gone. Your photo files are not touched.

        The current catalog is kept as "Catalog before restore.sqlite", so this can be undone.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore and Reopen")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        CatalogBackup.scheduleRestore(from: backup)
        relaunch()
    }

    /// Opens a fresh copy of the app a moment after this one quits.
    @MainActor
    private func relaunch() {
        let bundle = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1.5; /usr/bin/open \"$0\"", bundle]
        try? task.run()
        NSApp.terminate(nil)
    }

    func flashBackupStatus(_ text: String) {
        backupStatus = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.backupStatus == text { self?.backupStatus = nil }
        }
    }

    /// "Last backup: today 09:14" for the menu.
    var lastBackupDescription: String {
        guard let date = CatalogBackup.lastBackup else { return "No backup yet" }
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Last backup: " + formatter.string(from: date)
    }
}
