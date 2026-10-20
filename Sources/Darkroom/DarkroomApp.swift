import SwiftUI
import AppKit

/// Makes the app behave like a normal Mac app (Dock icon, keyboard focus)
/// when it is run straight from the Swift package.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct DarkroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LibraryStore()

    var body: some Scene {
        WindowGroup(Theme.appFullName) {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1100, minHeight: 680)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1500, height: 940)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(Theme.appName)") { store.guideTab = .about }
            }
            CommandGroup(replacing: .help) {
                Button("\(Theme.appName) Guide") { store.guideTab = .features }
                    .keyboardShortcut("/", modifiers: [.command, .shift])
                Button("Opening LumaGrader on a Mac (Security)") { store.guideTab = .security }
                if Support.url != nil {
                    Divider()
                    Button("Support LumaGrader on Ko-fi…") { Support.open() }
                }
            }
            CommandGroup(after: .newItem) {
                Button("Import Photos…") { store.beginImport() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Menu("Tethered Capture") {
                    Button("Start Tethered Capture…") { store.beginTether() }
                        .disabled(store.isTethering)
                    Button("Stop Tethered Capture") { store.stopTether() }
                        .disabled(!store.isTethering)
                    Toggle("Show New Shots", isOn: $store.tetherShowNew)
                }
                Button("Add Folder Without Copying…") {
                    if let url = FolderPicker.chooseFolder() {
                        Task { await store.addFolder(url) }
                    }
                }
                Button("Export…") { store.beginExport() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(store.selectedPhotoID == nil)
                Button("Export with Previous") { store.exportWithPrevious() }
                    .keyboardShortcut("e", modifiers: [.command, .shift, .option])
                    .disabled(!store.canExportWithPrevious)
                Divider()
                Button("Page Setup…") { store.pageSetup() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Print…") { store.printSelected() }
                    .keyboardShortcut("p", modifiers: [.command])
                    .disabled(store.selectedPhotoID == nil)
                Button("Print Module") { store.setViewMode(.print) }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                    .disabled(store.selectedPhotoID == nil)
                Divider()
                Menu("Catalog Backup") {
                    Text(store.lastBackupDescription)
                    Button("Back Up Now") { store.backUpCatalogNow() }
                        .disabled(store.isBackingUp || store.catalogURL == nil)
                    Toggle("Back Up Daily", isOn: $store.autoBackup)
                    Divider()
                    Button("Choose Backup Folder…") { store.chooseBackupFolder() }
                    Button("Show Backups in Finder") { store.showBackupsInFinder() }
                    Divider()
                    Button("Restore from Backup…") { store.restoreCatalog() }
                }
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Edit") { store.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo Edit") { store.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Command Palette…") { store.showCommandPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Select None") { store.selectNone() }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Select Picks") { store.selectFlagged(.pick) }
                Button("Invert Selection") { store.invertSelection() }
            }
            CommandMenu("Photo") {
                Button("Copy Settings…") { store.settingsSheet = .copy }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(store.selectedPhotoID == nil)
                Button("Copy All Settings") { store.copyAllSettings() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(store.selectedPhotoID == nil)
                Button("Paste Settings") { store.pasteSettings() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(!store.canPaste)
                Button("Paste Settings from Previous") { store.pasteFromPrevious() }
                    .keyboardShortcut("v", modifiers: [.command, .option])
                    .disabled(!store.canPasteFromPrevious)
                Button("Sync Settings…") { store.settingsSheet = .sync }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!store.canSync)
                Toggle("Auto Sync", isOn: Binding(get: { store.autoSync }, set: { store.autoSync = $0 }))
                    .keyboardShortcut("a", modifiers: [.command, .shift, .option])
                Button("Save Settings as Preset…") { store.settingsSheet = .savePreset }
                    .disabled(store.selectedPhotoID == nil)
                Button("Import Presets…") { store.chooseAndImportPresets() }
                Divider()
                Button("Auto Tone") { store.autoSettings(tone: true, whiteBalance: false) }
                    .keyboardShortcut("u", modifiers: .command)
                    .disabled(store.selectedPhotoID == nil || store.batchProgress != nil)
                Button("Auto White Balance") { store.autoSettings(tone: false, whiteBalance: true) }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(store.selectedPhotoID == nil || store.batchProgress != nil)
                Button("Auto Tone + White Balance") { store.autoSettings(tone: true, whiteBalance: true) }
                    .keyboardShortcut("u", modifiers: [.command, .option])
                    .disabled(store.selectedPhotoID == nil || store.batchProgress != nil)
                Button("Reset Settings") { store.resetSettings() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(store.selectedPhotoID == nil)
                Button("Convert to Black & White") { store.toggleBlackWhite() }
                    .disabled(store.selectedPhotoID == nil)
                Button("Rotate Left") { store.rotate(clockwise: false) }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(store.selectedPhotoID == nil)
                Button("Rotate Right") { store.rotate(clockwise: true) }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(store.selectedPhotoID == nil)
                Button("Auto-Rotate Portraits") { store.autoRotateSelected() }
                    .disabled(store.selectedPhotoID == nil || store.orientProgress != nil)
                Toggle("Auto-Rotate Portraits on Import", isOn: $store.autoRotatePortraits)
                Divider()
                Button("Delete Photo… (⌫)") { store.confirmDeleteSelected() }
                    .disabled(store.selectedPhotoID == nil)
                Button("Create Virtual Copy") { store.createVirtualCopy() }
                    .keyboardShortcut("'", modifiers: .command)
                    .disabled(store.selectedPhotoID == nil)
                Button("People…") { store.showPeopleSheet = true }
                Button("Find Faces") { store.findFaces() }
                    .disabled(store.faceProgress != nil || store.photos.isEmpty)
                Menu("Photo Merge") {
                    Button("HDR…") { store.beginHDRMerge() }
                        .keyboardShortcut("h", modifiers: .control)
                        .disabled(!store.canMergeHDR)
                }
                Divider()
                Toggle("Focus Peaking (⇧F)", isOn: Binding(get: { store.focusPeaking },
                                                          set: { _ in store.toggleFocusPeaking() }))
                Picker("Focus Peaking Sensitivity", selection: $store.focusSensitivity) {
                    ForEach(FocusPeaking.Sensitivity.allCases) { Text($0.title).tag($0) }
                }
                Button("Zoom to Sharpest Area (⇧Z)") { store.zoomToSharpest() }
                    .disabled(store.selectedPhotoID == nil)
                Divider()
                Button("Before / After") { store.develop.toggleBeforeAfter() }
                    .disabled(store.viewMode != .develop)
                Picker("Before / After View", selection: Binding(
                    get: { store.develop.compareLayout },
                    set: { store.develop.compareLayout = $0 })
                ) {
                    ForEach(CompareLayout.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(store.viewMode != .develop)
                Button("Show Clipping") { store.develop.toggleClipping() }
                    .disabled(store.viewMode != .develop)
                Divider()
                Button("Healing (Q)") { _ = store.handle(.healing) }
                    .disabled(store.selectedPhotoID == nil)
                Menu("Masking") {
                    Button("Masking Panel (⇧W)") { store.develop.toggleMasking() }
                    Divider()
                    Button("Select Subject") { store.develop.createMask(.subject) }
                    Button("Select Background") { store.develop.createMask(.subject, invert: true) }
                    Button("Brush (K)") { store.develop.createMask(.brush) }
                    Button("Linear Gradient (M)") { store.develop.createMask(.linear) }
                    Button("Radial Gradient (⇧M)") { store.develop.createMask(.radial) }
                    Button("Luminance Range") { store.develop.createMask(.luminanceRange) }
                    Button("Color Range") { store.develop.createMask(.colorRange) }
                }
                .disabled(store.viewMode != .develop)
            }
        }
    }
}
