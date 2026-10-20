import SwiftUI
import AppKit

// MARK: - Start sheet

/// File ▸ Tethered Capture ▸ Start…: choose the hot folder, then point EOS Utility at it.
struct TetherSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var base = LibraryStore.tetherBaseFolder
    @State private var session = UserDefaults.standard.string(forKey: LibraryStore.TetherDefaults.session) ?? ""
    @State private var copied = false

    private var folder: URL { LibraryStore.tetherFolder(base: base, session: session) }
    @State private var eosUtility: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tethered Capture").font(.system(size: 15, weight: .semibold))
                    Text("Every shot saved into the folder below appears in LumaGrader right away.")
                        .font(Theme.smallFont)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Session name") {
                        TextField("e.g. Santos Wedding", text: $session)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                    }
                    LabeledContent("Saved in") {
                        HStack {
                            Text(base.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 220, alignment: .leading)
                            Button("Choose…") {
                                if let url = FolderPicker.chooseFolder(
                                    prompt: "Use Folder",
                                    message: "Choose where tethered sessions go. Each session gets its own dated folder inside.") {
                                    base = url
                                }
                            }
                        }
                    }
                    LabeledContent("Hot folder") {
                        HStack {
                            Text(folder.path)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .frame(maxWidth: 260, alignment: .leading)
                            Button(copied ? "Copied" : "Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(folder.path, forType: .string)
                                copied = true
                            }
                        }
                    }
                }
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Canon R8 with EOS Utility").font(.system(size: 12, weight: .semibold))
                step(1, "Connect the camera with USB (or pair it over Wi-Fi) and turn it on.")
                step(2, "Click Start below, then open EOS Utility ▸ Remote Shooting.")
                step(3, "In EOS Utility's Preferences ▸ Destination Folder, choose the hot folder above (Copy Path, then ⇧⌘G in the folder dialog to paste it).")
                step(4, "Shoot from the camera or from EOS Utility. Each photo shows up here as soon as it's saved.")
                Text("Works the same with any tether or transfer app that saves to a folder (Nikon, Sony, Fujifilm, Wi-Fi/FTP).")
                    .font(Theme.smallFont)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }

            LabeledContent("Develop Settings") {
                TetherDevelopPicker()
                    .frame(width: 260, alignment: .leading)
            }
            .help("Applied to each new shot: a preset, or the settings of the shot before it")
            Toggle("Show each new shot (Loupe, or stay in Develop)", isOn: $store.tetherShowNew)

            HStack {
                if let eosUtility {
                    Button("Open EOS Utility") { NSWorkspace.shared.open(eosUtility) }
                } else {
                    Text("EOS Utility isn't installed. Get it free from Canon's support page for the EOS R8.")
                        .font(Theme.smallFont)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") {
                    store.startTether(folder: folder, base: base, session: session)
                    if let eosUtility { NSWorkspace.shared.open(eosUtility) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { eosUtility = LibraryStore.eosUtilityURL() }
        .onChange(of: session) { _, _ in copied = false }
        .onChange(of: base) { _, _ in copied = false }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Theme.accent))
            Text(text)
                .font(Theme.bodyFont)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Bar over the centre while tethering

struct TetherBar: View {
    @EnvironmentObject private var store: LibraryStore
    let state: TetherState
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
            Text("TETHERED")
                .font(Theme.titleFont)
                .tracking(1)
                .foregroundStyle(Theme.textBright)
            Text(state.folder.lastPathComponent)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(state.shots == 1 ? "1 shot" : "\(state.shots) shots")
                .foregroundStyle(Theme.textDim)
            if let name = state.lastFileName {
                Text("Last: \(name)")
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Waiting for the first shot…")
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            HStack(spacing: 4) {
                Text("Develop").foregroundStyle(Theme.textDim)
                TetherDevelopPicker()
                    .frame(maxWidth: 170)
            }
            .help("Settings for each new shot. Same as Previous: edit one shot, the next ones follow.")
            Toggle("Show New", isOn: $store.tetherShowNew)
                .toggleStyle(.checkbox)
                .help("Jump to each new shot")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([state.folder])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text)
            .help("Show the hot folder in Finder")
            Button("Stop") { store.stopTether() }
                .controlSize(.small)
                .help("Stop tethered capture (the photos stay in the catalog)")
        }
        .font(Theme.bodyFont)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.panelHeader)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }
}

// MARK: - Develop Settings menu

/// None / Same as Previous / the develop presets, for new tethered shots.
struct TetherDevelopPicker: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        Menu {
            Button("None") { store.tetherDevelop = .off }
            Button("Same as Previous") { store.tetherDevelop = .previous }
            if !store.presets.isEmpty {
                Divider()
                ForEach(store.presets) { preset in
                    Button(preset.name) { store.tetherDevelop = .preset(preset.id) }
                }
            }
        } label: {
            Text(store.tetherDevelopTitle(store.tetherDevelop))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize(horizontal: false, vertical: true)
    }
}
