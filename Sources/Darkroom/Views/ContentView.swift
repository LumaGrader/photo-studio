import SwiftUI

/// Lightroom Classic-style window:
///   top bar (identity + Library | Develop)
///   left panel · centre (photo/grid + toolbar) · right panel
///   filmstrip
/// Tab hides the side panels, Shift-Tab hides everything, F toggles full screen.
struct ContentView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var keyMonitor = KeyMonitor()
    @AppStorage("thumbnailSize") private var thumbnailSize: Double = 180

    var body: some View {
        VStack(spacing: 0) {
            TopBar(exports: store.exportQueue)
            HStack(spacing: 0) {
                if store.showSidePanels {
                    LeftPanel()
                        .frame(width: Theme.sidePanelWidth)
                    Rectangle().fill(Theme.separator).frame(width: 1)
                }
                VStack(spacing: 0) {
                    if let tether = store.tether {
                        TetherBar(state: tether)
                    }
                    center
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if store.hasSource {
                        CenterToolbar(session: store.develop)
                    }
                }
                .background(Theme.center)
                if store.showSidePanels {
                    Rectangle().fill(Theme.separator).frame(width: 1)
                    RightPanel()
                        .frame(width: Theme.rightPanelWidth)
                }
            }
            if store.showFilmstrip, store.hasSource {
                Rectangle().fill(Theme.separator).frame(height: 1)
                Filmstrip()
                    .frame(height: Theme.filmstripHeight)
            }
        }
        .background(Theme.window)
        .overlay { SupportPromptOverlay(exports: store.exportQueue) }
        .ignoresSafeArea()
        .font(Theme.bodyFont)
        .onAppear {
            keyMonitor.install { command in store.handle(command) }
            // First launch: show what LumaGrader can do.
            if !UserDefaults.standard.bool(forKey: "guide.seen") {
                UserDefaults.standard.set(true, forKey: "guide.seen")
                store.guideTab = .features
            }
        }
        .sheet(isPresented: exportShown) {
            ExportSheet(photos: store.exportPhotos ?? []) {
                store.exportPhotos = nil
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $store.showCullSheet) {
            CullSheet().environmentObject(store)
        }
        .sheet(isPresented: $store.showHDRSheet) {
            HDRMergeSheet().environmentObject(store)
        }
        .sheet(isPresented: $store.showProofingSheet) {
            ProofingSheet().environmentObject(store)
        }
        .sheet(isPresented: $store.showPicksImport) {
            PicksImportSheet().environmentObject(store)
        }
        .sheet(isPresented: $store.showPeopleSheet) {
            PeopleSheet().environmentObject(store)
        }
        .sheet(item: $store.guideTab) { tab in
            GuideView(tab: tab).environmentObject(store)
        }
        .sheet(isPresented: $store.showTetherSheet) {
            TetherSheet().environmentObject(store)
        }
        .sheet(isPresented: $store.showImportSheet) {
            ImportSheet().environmentObject(store)
        }
        .sheet(isPresented: $store.showCommandPalette) {
            CommandPalette().environmentObject(store)
        }
        .sheet(item: $store.settingsSheet) { kind in
            SettingsGroupsSheet(kind: kind) {
                store.settingsSheet = nil
            } onConfirm: { name, groups in
                switch kind {
                case .copy: store.copySettings(groups: groups)
                case .savePreset: store.savePreset(name: name, groups: groups)
                case .sync: store.syncSettings(groups: groups)
                }
                store.settingsSheet = nil
            }
        }
        .alert(store.notice?.title ?? "", isPresented: noticeShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.notice?.message ?? "")
        }
        .alert("Something went wrong", isPresented: errorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var center: some View {
        if !store.hasSource {
            EmptyLibraryView()
        } else if store.selectedPhoto == nil {
            VStack(spacing: 0) {
                LibraryFilterBar()
                GridView(thumbnailSize: CGFloat(thumbnailSize))
            }
        } else {
            switch store.viewMode {
            case .grid:
                VStack(spacing: 0) {
                    LibraryFilterBar()
                    GridView(thumbnailSize: CGFloat(thumbnailSize))
                }
            case .loupe:
                LoupeView()
            case .compare:
                if store.compareLeft != nil {
                    CompareView()
                } else {
                    LoupeView()
                }
            case .survey:
                if store.surveyPhotos.count > 1 {
                    SurveyView()
                } else {
                    LoupeView()
                }
            case .develop:
                DevelopPreview(session: store.develop, cropTool: store.cropTool)
            case .print:
                PrintPreview(model: store.printModel)
            }
        }
    }

    private var exportShown: Binding<Bool> {
        Binding(
            get: { store.exportPhotos != nil },
            set: { if !$0 { store.exportPhotos = nil } })
    }

    private var errorShown: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } })
    }

    private var noticeShown: Binding<Bool> {
        Binding(
            get: { store.notice != nil },
            set: { if !$0 { store.notice = nil } })
    }
}

struct EmptyLibraryView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(Theme.textDim)
            Text("No photos yet")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Theme.text)
            Text("Import a folder to start. Photos stay where they are on your Mac.")
                .foregroundStyle(Theme.textDim)
            Button("Import Folder…") {
                if let url = FolderPicker.chooseFolder() {
                    Task { await store.addFolder(url) }
                }
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.center)
    }
}
