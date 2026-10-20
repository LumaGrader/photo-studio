import SwiftUI
import AppKit

/// File ▸ Create Proofing Gallery…: a folder (and .zip) of the selected photos that a client
/// opens in any browser to heart favourites, add notes and send the list back.
struct ProofingSheet: View {
    @EnvironmentObject private var store: LibraryStore

    @AppStorage("proofing.photographer") private var photographer = ""
    @AppStorage("proofing.email") private var email = ""
    @AppStorage("proofing.messenger") private var messenger = ""
    @AppStorage("proofing.longEdge") private var longEdge = 2048
    @AppStorage("proofing.watermark") private var watermark = true
    @AppStorage("proofing.folder") private var folderPath = ""
    @State private var title = ""
    @State private var message = ""

    private var parentFolder: URL {
        if !folderPath.isEmpty { return URL(fileURLWithPath: folderPath, isDirectory: true) }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Create Proofing Gallery", systemImage: "heart.text.square").font(.title3.weight(.semibold))
            if let result = store.proofingResult {
                finished(result)
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(store.proofingProgress != nil)
        .onAppear {
            if title.isEmpty { title = store.proofingDefaultTitle }
        }
    }

    private var form: some View {
        let count = store.proofingPhotos.count
        let running = store.proofingProgress != nil
        return VStack(alignment: .leading, spacing: 14) {
            Text("Makes a small website of the \(count) selected photo\(count == 1 ? "" : "s") for your client. They open it in any browser (phone or computer, no internet needed), tap a heart on their favourites, add notes, and send you the list. Import Client Picks then marks those photos Purple.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Gallery title", text: $title, prompt: Text("e.g. Ana & Mark Prenup"))
                TextField("Photos by", text: $photographer, prompt: Text("Your name or studio"))
                TextField("Your email", text: $email, prompt: Text("Optional: adds a Send by email button"))
                TextField("Messenger username", text: $messenger, prompt: Text("Optional: e.g. malayte (from m.me/malayte)"))
                TextField("Note to the client", text: $message, prompt: Text("Optional: e.g. Please pick 50 for the album"), axis: .vertical)
                    .lineLimit(1...3)
                Picker("Photo size", selection: $longEdge) {
                    Text("1600 px (smallest file)").tag(1600)
                    Text("2048 px").tag(2048)
                    Text("2560 px (sharpest)").tag(2560)
                }
                Toggle("Watermark the photos", isOn: $watermark)
                    .help("Uses the watermark from Export; \"PROOF\" when none is set up")
                LabeledContent("Save in") {
                    HStack {
                        Text(parentFolder.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") {
                            if let url = FolderPicker.chooseFolder(prompt: "Choose", message: "Where should the proofing gallery go?") {
                                folderPath = url.path
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(running)

            if let progress = store.proofingProgress {
                HStack(spacing: 8) {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    Text("\(progress.done) of \(progress.total)").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let error = store.proofingError {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { store.showProofingSheet = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(running)
                Button("Create Gallery") {
                    store.createProofingGallery(ProofingOptions(
                        title: title, photographer: photographer, email: email, messenger: messenger,
                        message: message, longEdge: longEdge, watermark: watermark, parentFolder: parentFolder))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(running || count == 0)
            }
        }
    }

    private func finished(_ result: ProofingGallery.Result) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Gallery ready: \(result.manifest.entries.count) photos", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)
            Text("Send the client the **\(result.zip?.lastPathComponent ?? result.folder.lastPathComponent)** file (Google Drive, Messenger, WeTransfer or a USB drive). They open it and double-click **index.html**.")
                .fixedSize(horizontal: false, vertical: true)
            Text("When they send their list back, copy it and choose File ▸ Import Client Picks… The picked photos get the Purple label.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !result.failures.isEmpty {
                Text("Skipped \(result.failures.count): " + result.failures.prefix(3).joined(separator: " "))
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Preview in Browser") {
                    NSWorkspace.shared.open(result.folder.appendingPathComponent("index.html"))
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([result.zip ?? result.folder])
                }
                Spacer()
                Button("Done") {
                    store.showProofingSheet = false
                    store.proofingResult = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// File ▸ Import Client Picks…: paste the list from the gallery's "Send my picks".
struct PicksImportSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var text = ""
    @State private var applied: Int?

    var body: some View {
        let picks = ProofingPicks.parse(text)
        let match = store.matchPicks(picks)
        VStack(alignment: .leading, spacing: 12) {
            Label("Import Client Picks", systemImage: "heart.circle").font(.title3.weight(.semibold))
            Text("Paste the list your client sent from the proofing gallery. Their favourites get the Purple label; your own flags and stars stay as they are.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 170)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .disabled(applied != nil)
            HStack {
                Button("Paste") {
                    if let s = NSPasteboard.general.string(forType: .string) { text = s; applied = nil }
                }
                .disabled(applied != nil)
                Spacer()
                summary(match)
            }

            if applied != nil, !picks.notes.isEmpty {
                Divider()
                Text("Notes from \(picks.client ?? "the client")").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(picks.notes, id: \.n) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: item.favorite ? "heart.fill" : "text.bubble")
                                    .foregroundStyle(item.favorite ? Color.pink : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("#\(item.n) \(item.name)").font(.callout.weight(.semibold))
                                    Text(item.note).font(.callout).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                if let id = match.photoIDs[item.n] {
                                    Button("Show") { store.reveal(photoID: id) }.controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            HStack {
                if let applied {
                    Label("\(applied) photo\(applied == 1 ? "" : "s") marked Purple", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Show Client Picks") {
                        store.showClientPicks()
                        store.showPicksImport = false
                    }
                    Button("Done") { store.showPicksImport = false }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Spacer()
                    Button("Cancel") { store.showPicksImport = false }
                        .keyboardShortcut(.cancelAction)
                    Button(match.favoriteIDs.isEmpty ? "Mark Purple" : "Mark \(match.favoriteIDs.count) Purple") {
                        applied = store.applyPicks(match)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(match.favoriteIDs.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            // The client's list is often already copied.
            if let s = NSPasteboard.general.string(forType: .string), s.contains("Gallery ID:") { text = s }
        }
    }

    @ViewBuilder
    private func summary(_ match: LibraryStore.PicksMatch) -> some View {
        let picks = match.picks
        if picks.isEmpty {
            Text(text.isEmpty ? "Nothing pasted yet." : "No picks found. Paste the whole message, including the #001 lines.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(picks.title ?? "Gallery") · \(picks.favorites.count) favourite\(picks.favorites.count == 1 ? "" : "s") · \(picks.notes.count) note\(picks.notes.count == 1 ? "" : "s")")
                    .font(.callout)
                if !match.unmatched.isEmpty {
                    Text("\(match.unmatched.count) not found here. Open the shoot's folder and paste again.")
                        .font(.caption).foregroundStyle(.orange)
                } else if match.manifest == nil {
                    Text("Matched by file name (gallery made on another Mac).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
