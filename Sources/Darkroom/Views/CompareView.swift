import SwiftUI

/// Two photos side by side. Left = "Select" (stays put), right = "Candidate"
/// (← / → steps through the shoot). Ratings and flags go to the candidate.
struct CompareView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                pane(store.compareLeft, label: "Select", isActive: false)
                pane(store.selectedPhoto, label: "Candidate", isActive: true)
            }
            HStack {
                Button {
                    store.swapCompare()
                } label: {
                    Label("Swap", systemImage: "arrow.left.arrow.right")
                }
                .help("Make the candidate the select")
                Spacer()
                if let photo = store.selectedPhoto {
                    PhotoInfoBar(photo: photo)
                }
                Spacer()
                Text("← → change candidate").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Theme.panel)
        }
    }

    private func pane(_ photo: Photo?, label: String, isActive: Bool) -> some View {
        PhotoPane(photo: photo, peaking: store.focusPeaking ? store.focusSensitivity : nil)
            .contextMenu {
                if let photo { PhotoContextMenu(photo: photo, store: store) }
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption.weight(.bold))
                    if let photo {
                        Text(photo.fileName).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                .padding(10)
            }
            .overlay(
                Rectangle().stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 2))
    }
}
