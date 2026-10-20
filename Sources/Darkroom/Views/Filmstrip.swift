import SwiftUI
import AppKit

/// Bottom filmstrip, visible in every module (Shift-Tab hides it), with an info line
/// like Lightroom's: "Folder: name   349 photos / 2 selected / IMG_0519.CR3".
struct Filmstrip: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        let photos = store.visiblePhotos
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(infoLine(shown: photos.count))
                    .font(Theme.smallFont)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                ToolbarIconButton(systemImage: "chevron.left", help: "Previous photo (←)") { store.moveSelection(by: -1) }
                ToolbarIconButton(systemImage: "chevron.right", help: "Next photo (→)") { store.moveSelection(by: 1) }
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Theme.panel)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(spacing: 4) {
                        ForEach(photos) { photo in
                            FilmstripCell(
                                photo: photo,
                                isActive: photo.id == store.selectedPhotoID,
                                isSelected: store.isSelected(photo.id))
                            .id(photo.id)
                            .onTapGesture(count: 2) {
                                if !store.isDevelopModule, !store.isPrintModule { store.open(photo) }
                            }
                            .simultaneousGesture(TapGesture().onEnded {
                                let modifiers = NSEvent.modifierFlags
                                store.click(photo, command: modifiers.contains(.command), shift: modifiers.contains(.shift))
                            })
                            .contextMenu { PhotoContextMenu(photo: photo, store: store) }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
                .onChange(of: store.selectedPhotoID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                }
                .onAppear {
                    if let id = store.selectedPhotoID { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .background(Theme.filmstrip)
    }

    private func infoLine(shown: Int) -> String {
        var parts: [String] = []
        if let collection = store.selectedCollection {
            parts.append("Collection: \(collection.name)")
        } else if let folder = store.selectedFolder {
            parts.append("Folder: \(folder.name)")
        }
        var counts = "\(shown) photos"
        if store.selectionCount > 1 { counts += " / \(store.selectionCount) selected" }
        if let photo = store.selectedPhoto { counts += " / \(photo.displayName)" }
        parts.append(counts)
        return parts.joined(separator: "     ")
    }
}

struct FilmstripCell: View {
    let photo: Photo
    let isActive: Bool
    let isSelected: Bool

    @State private var image: CGImage?

    private struct LoadKey: Equatable {
        let url: URL
        let develop: DevelopSettings
    }

    var body: some View {
        ZStack {
            isSelected ? (isActive ? Theme.selectionActive : Theme.selection) : Theme.panel
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
                    .padding(4)
            }
        }
        .frame(width: 104, height: 76)
        .overlay(alignment: .topLeading) {
            FlagBadge(flag: photo.flag).scaleEffect(0.75).padding(1)
        }
        .overlay(alignment: .bottomLeading) {
            if photo.rating > 0 {
                Text(String(repeating: "★", count: photo.rating))
                    .font(.system(size: 8))
                    .foregroundStyle(.yellow)
                    .padding(3)
            }
        }
        .overlay(alignment: .bottom) {
            if let color = photo.label.color {
                Rectangle().fill(color).frame(height: 3)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(isActive ? Theme.accent : Color.clear, lineWidth: 1.5))
        .opacity(photo.flag == .reject ? 0.45 : 1)
        .contentShape(Rectangle())
        .task(id: LoadKey(url: photo.url, develop: photo.develop)) {
            let loaded = await ImageLoader.shared.displayImage(for: photo, maxPixel: ThumbnailDiskCache.maxPixel)
            if !Task.isCancelled, let loaded { image = loaded }
        }
    }
}
