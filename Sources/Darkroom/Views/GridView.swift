import SwiftUI
import AppKit

struct GridView: View {
    @EnvironmentObject private var store: LibraryStore
    let thumbnailSize: CGFloat

    var body: some View {
        let photos = store.visiblePhotos
        Group {
            if photos.isEmpty {
                emptyState
            } else {
                grid(photos)
            }
        }
        .background(Theme.center)
    }

    private func grid(_ photos: [Photo]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: thumbnailSize + 12), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(photos) { photo in
                        ThumbnailCell(
                            photo: photo,
                            size: thumbnailSize,
                            isActive: photo.id == store.selectedPhotoID,
                            isSelected: store.isSelected(photo.id),
                            isStacked: store.pairedRawIDs.contains(photo.id),
                            analysis: store.analysis[photo.id])
                        .id(photo.id)
                        .onTapGesture(count: 2) { store.open(photo) }
                        .simultaneousGesture(TapGesture().onEnded {
                            let modifiers = NSEvent.modifierFlags
                            store.click(photo,
                                        command: modifiers.contains(.command),
                                        shift: modifiers.contains(.shift))
                        })
                        .contextMenu { PhotoContextMenu(photo: photo, store: store) }
                    }
                }
                .padding(12)
            }
            .onChange(of: store.selectedPhotoID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
            .onAppear {
                if let id = store.selectedPhotoID { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text(store.photos.isEmpty ? "No photos in this folder" : "No photos match the filter")
                .font(.headline)
            if !store.photos.isEmpty {
                Button("Show all photos") { store.clearFilters() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ThumbnailCell: View {
    let photo: Photo
    let size: CGFloat
    let isActive: Bool
    let isSelected: Bool
    let isStacked: Bool
    var analysis: PhotoAnalysis? = nil

    @State private var image: CGImage?
    @State private var failed = false

    private struct LoadKey: Equatable {
        let url: URL
        let develop: DevelopSettings
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Rectangle().fill(Theme.center)
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFit()
                } else if failed {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .help("Can't read this file (missing or unsupported)")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: size, height: size)
            .overlay(alignment: .topLeading) { FlagBadge(flag: photo.flag).padding(4) }
            .overlay(alignment: .topTrailing) { badges.padding(4) }
            .overlay(alignment: .bottomLeading) {
                if let analysis { aiBadge(analysis).padding(4) }
            }

            HStack(spacing: 4) {
                StarsView(rating: photo.rating)
                if photo.label != .none {
                    LabelSwatch(label: photo.label, isOn: true)
                        .help("\(photo.label.name) label")
                }
                Spacer(minLength: 4)
                Text(photo.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)
            .frame(width: size)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? (isActive ? Theme.selectionActive : Theme.selection) : Theme.panel))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Theme.accent : Color.black.opacity(0.4), lineWidth: isActive ? 1.5 : 1))
        .overlay(alignment: .bottom) {
            // Colour label: a strip along the bottom of the cell (like Lightroom's tinted cell).
            if let color = photo.label.color {
                Rectangle().fill(color).frame(height: 3).padding(.horizontal, 1).padding(.bottom, 1)
            }
        }
        .opacity(photo.flag == .reject ? 0.4 : 1)
        .contentShape(Rectangle())
        .task(id: LoadKey(url: photo.url, develop: photo.develop)) {
            let loaded = await ImageLoader.shared.displayImage(
                for: photo, maxPixel: ThumbnailDiskCache.maxPixel)
            if Task.isCancelled { return } // scrolled away; try again when visible
            if let loaded {
                image = loaded
                failed = false
            } else if image == nil {
                failed = true
            }
        }
    }

    /// AI Cull: suggested stars, plus warnings for blur / closed eyes.
    private func aiBadge(_ a: PhotoAnalysis) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles").font(.system(size: 8))
            Text("\(a.stars)★").font(.system(size: 9, weight: .bold))
            if a.isBlurry {
                Image(systemName: "camera.metering.unknown").font(.system(size: 9)).help("Looks blurry")
            }
            if a.eyesClosed > 0 {
                Image(systemName: "eye.slash").font(.system(size: 9)).help("Closed eyes")
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
        .help(String(format: "AI score %.0f / 100 · sharpness %.0f%%", a.score * 100, a.sharpness * 100))
    }

    private var badges: some View {
        HStack(spacing: 3) {
            if photo.hasEdits {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 9, weight: .bold))
                    .help("Edited")
            }
            if photo.isRaw {
                Text(isStacked ? "RAW+JPG" : "RAW")
                    .font(.system(size: 9, weight: .bold))
            }
            if photo.isVirtualCopy {
                Text("VC\(photo.copyIndex)")
                    .font(.system(size: 9, weight: .bold))
                    .help("Virtual copy: same file, its own edits")
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
        .opacity(photo.hasEdits || photo.isRaw || photo.isVirtualCopy ? 1 : 0)
    }
}

struct StarsView: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: index < rating ? "star.fill" : "star")
                    .foregroundStyle(index < rating ? Color.yellow : Color.secondary.opacity(0.5))
            }
        }
        .accessibilityLabel("\(rating) stars")
    }
}

/// A small colour-label dot (filled when on, faint when off).
struct LabelSwatch: View {
    let label: ColorLabel
    var isOn: Bool

    var body: some View {
        let color = label.color ?? .clear
        Circle()
            .fill(isOn ? color : color.opacity(0.25))
            .overlay(Circle().stroke(color, lineWidth: 1))
            .frame(width: 9, height: 9)
    }
}

extension ColorLabel {
    /// Display colour (nil for None).
    var color: Color? {
        switch self {
        case .none: return nil
        case .red: return Color(red: 0.86, green: 0.27, blue: 0.25)
        case .yellow: return Color(red: 0.93, green: 0.78, blue: 0.22)
        case .green: return Color(red: 0.36, green: 0.70, blue: 0.33)
        case .blue: return Color(red: 0.27, green: 0.52, blue: 0.88)
        case .purple: return Color(red: 0.62, green: 0.40, blue: 0.82)
        }
    }
}

struct FlagBadge: View {
    let flag: Flag

    var body: some View {
        switch flag {
        case .pick:
            Image(systemName: "flag.fill")
                .foregroundStyle(.white)
                .padding(3)
                .background(.black.opacity(0.6), in: Circle())
                .help("Pick")
        case .reject:
            Image(systemName: "xmark")
                .foregroundStyle(.red)
                .padding(3)
                .background(.black.opacity(0.6), in: Circle())
                .help("Rejected")
        case .unflagged:
            EmptyView()
        }
    }
}
