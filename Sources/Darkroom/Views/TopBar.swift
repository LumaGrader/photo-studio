import SwiftUI

/// Identity plate on the left, module switcher (Library · Develop · Print pill) on the right.
struct TopBar: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject var exports: ExportQueue

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 76) // room for the window buttons
            HStack(spacing: 8) {
                AppMark(size: 20)
                // LumaGrader wordmark: "Luma" white + "Grader" in the accent blue.
                (Text("Luma").foregroundColor(Theme.textBright) + Text("Grader").foregroundColor(Theme.accent))
                    .font(.system(size: 16, weight: .bold))
                Text("PHOTO STUDIO")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(Theme.textDim)
                    .padding(.top, 2)
            }
            if store.isImporting {
                ProgressView().controlSize(.small).padding(.leading, 10)
                Text("Importing…").font(Theme.smallFont).foregroundStyle(Theme.textDim).padding(.leading, 4)
            }
            Spacer()
            backupStatus
            orientStatus
            batchStatus
            faceStatus
            importStatus
            exportStatus
            SupportButton()
                .padding(.trailing, 12)
            // Module switcher: the app's pill instead of Lightroom's "Library | Develop" text.
            HStack(spacing: 2) {
                moduleButton("Library", icon: "square.grid.2x2",
                             active: !store.isDevelopModule && !store.isPrintModule) { store.showLibrary() }
                moduleButton("Develop", icon: "slider.horizontal.3", active: store.isDevelopModule) {
                    store.setViewMode(.develop)
                }
                .disabled(store.selectedPhotoID == nil)
                moduleButton("Print", icon: "printer", active: store.isPrintModule) { store.setViewMode(.print) }
                    .disabled(store.selectedPhotoID == nil)
            }
            .padding(3)
            .background(Theme.panel, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.06), lineWidth: 1))
            Button {
                store.guideTab = .features
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textDim)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            .help("LumaGrader Guide: features, Mac security, about (⇧⌘/)")
            Color.clear.frame(width: 18)
        }
        .frame(height: 40)
        .background(Theme.window)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }

    @ViewBuilder
    private var orientStatus: some View {
        if let progress = store.orientProgress {
            HStack(spacing: 8) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 70)
                Text("Checking orientation \(progress.done) of \(progress.total)…")
                    .font(Theme.smallFont)
                    .foregroundStyle(Theme.textDim)
            }
            .padding(.trailing, 24)
        }
    }

    @ViewBuilder
    private var backupStatus: some View {
        if store.isBackingUp {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Backing up catalog…").font(Theme.smallFont).foregroundStyle(Theme.textDim)
            }
            .padding(.trailing, 24)
        } else if let text = store.backupStatus {
            Label(text, systemImage: "checkmark.circle")
                .font(Theme.smallFont)
                .foregroundStyle(Theme.textDim)
                .padding(.trailing, 24)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var importStatus: some View {
        if let progress = store.importProgress {
            HStack(spacing: 8) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 90)
                Text("Importing \(progress.done) of \(progress.total)…")
                    .font(Theme.smallFont)
                    .foregroundStyle(Theme.textDim)
                Button("Stop") { store.cancelImport() }
                    .controlSize(.mini)
            }
            .padding(.trailing, 24)
        }
    }

    @ViewBuilder
    private var faceStatus: some View {
        if let progress = store.faceProgress {
            HStack(spacing: 8) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 90)
                Text("\(progress.label) \(min(progress.done + 1, progress.total)) of \(progress.total)…")
                    .font(Theme.smallFont)
                    .foregroundStyle(Theme.textDim)
                Button("Stop") { store.cancelFaceScan() }
                    .controlSize(.mini)
            }
            .padding(.trailing, 24)
        }
    }

    @ViewBuilder
    private var batchStatus: some View {
        if let batch = store.batchProgress {
            HStack(spacing: 8) {
                ProgressView(value: Double(batch.done), total: Double(max(batch.total, 1)))
                    .frame(width: 90)
                Text("\(batch.label) \(min(batch.done + 1, batch.total)) of \(batch.total)…")
                    .font(Theme.smallFont)
                    .foregroundStyle(Theme.textDim)
                Button("Stop") { store.cancelBatch() }
                    .controlSize(.mini)
            }
            .padding(.trailing, 24)
        }
    }

    @ViewBuilder
    private var exportStatus: some View {
        if exports.isRunning {
            HStack(spacing: 8) {
                ProgressView(value: Double(exports.done), total: Double(max(exports.total, 1)))
                    .frame(width: 120)
                Text(exports.progressText).font(Theme.smallFont).foregroundStyle(Theme.textDim)
                Button("Stop") { exports.cancel() }
                    .controlSize(.mini)
            }
            .padding(.trailing, 24)
        } else if exports.total > 0 {
            HStack(spacing: 8) {
                Text(exports.failures.isEmpty
                     ? "Exported \(exports.done)"
                     : "Exported \(exports.done - exports.failures.count), \(exports.failures.count) failed")
                    .font(Theme.smallFont)
                    .foregroundStyle(exports.failures.isEmpty ? Theme.textDim : Color.orange)
                    .help(exports.failures.joined(separator: "\n"))
                Button("Show in Finder") { exports.showInFinder() }
                    .controlSize(.mini)
            }
            .padding(.trailing, 24)
        }
    }

    private func moduleButton(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 12, weight: active ? .semibold : .regular))
            }
            .foregroundStyle(active ? Theme.textBright : Theme.textDim)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background {
                if active {
                    Capsule().fill(Theme.raised)
                        .overlay(alignment: .bottom) {
                            Capsule().fill(Theme.accent).frame(width: 18, height: 2).offset(y: -2)
                        }
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title == "Library" ? "Library (G)" : title == "Develop" ? "Develop (D)" : "Print (⌥⌘P)")
    }
}
