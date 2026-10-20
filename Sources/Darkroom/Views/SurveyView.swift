import SwiftUI

/// Survey (N): every selected photo side by side, to pick the best of a burst.
/// Click a frame to make it active; flags, ratings and labels go to the active photo;
/// ← → move between them; ✕ drops a photo from the survey.
struct SurveyView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        let photos = store.surveyPhotos
        VStack(spacing: 0) {
            GeometryReader { geo in
                let layout = Self.grid(count: photos.count, in: geo.size)
                let spacing: CGFloat = 4
                let cellWidth = (geo.size.width - spacing * CGFloat(layout.columns - 1)) / CGFloat(layout.columns)
                let cellHeight = (geo.size.height - spacing * CGFloat(layout.rows - 1)) / CGFloat(layout.rows)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: spacing), count: layout.columns),
                          spacing: spacing) {
                    ForEach(photos) { photo in
                        frame(photo, isActive: photo.id == store.selectedPhotoID)
                            .frame(width: cellWidth, height: cellHeight)
                    }
                }
            }
            .padding(6)
            HStack {
                Text("\(photos.count) photos").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let photo = store.selectedPhoto {
                    PhotoInfoBar(photo: photo)
                }
                Spacer()
                Text("Click to choose · ← → move · P / X / 1–5 for the active photo · ✕ remove")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Theme.panel)
        }
    }

    private func frame(_ photo: Photo, isActive: Bool) -> some View {
        PhotoPane(photo: photo, peaking: store.focusPeaking ? store.focusSensitivity : nil)
            .contentShape(Rectangle())
            .onTapGesture { store.focusSurveyPhoto(photo.id) }
            .contextMenu { PhotoContextMenu(photo: photo, store: store) }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    FlagBadge(flag: photo.flag)
                    if photo.rating > 0 {
                        Text(String(repeating: "★", count: photo.rating)).font(.caption2).foregroundStyle(.yellow)
                    }
                    if photo.label != .none { LabelSwatch(label: photo.label, isOn: true) }
                }
                .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    store.removeFromSurvey(photo.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .padding(5)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help("Remove from the survey (the photo stays in the folder)")
                .padding(8)
            }
            .overlay(alignment: .bottomLeading) {
                Text(photo.displayName)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                    .padding(8)
            }
            .overlay(Rectangle().stroke(isActive ? Color.white.opacity(0.85) : Color.clear, lineWidth: 2))
            .opacity(photo.flag == .reject ? 0.45 : 1)
    }

    /// Columns × rows that give the biggest frames for `count` photos (3:2 photos).
    static func grid(count: Int, in size: CGSize) -> (columns: Int, rows: Int) {
        guard count > 0, size.width > 0, size.height > 0 else { return (1, 1) }
        var best = (columns: 1, rows: count)
        var bestArea: CGFloat = 0
        for columns in 1...count {
            let rows = Int((Double(count) / Double(columns)).rounded(.up))
            let w = size.width / CGFloat(columns), h = size.height / CGFloat(rows)
            // Largest 3:2 (or 2:3) photo that fits the cell.
            let fit = min(w, h * 1.5) * min(h, w / 1.5)
            let fitPortrait = min(w, h / 1.5) * min(h, w * 1.5)
            let area = max(fit, fitPortrait)
            if area > bestArea {
                bestArea = area
                best = (columns, rows)
            }
        }
        return best
    }
}
