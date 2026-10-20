import SwiftUI
import AppKit

struct LoupeView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        PhotoPane(photo: store.selectedPhoto, neighbors: neighbors,
                  zoom: $store.zoom, clickZoom: store.lastZoom,
                  peaking: store.focusPeaking ? store.focusSensitivity : nil,
                  focusZoomToken: store.focusZoomToken)
            .contextMenu {
                if let photo = store.selectedPhoto { PhotoContextMenu(photo: photo, store: store) }
            }
            .overlay(alignment: .topLeading) {
                // Lightroom-style info overlay (stars/flags live in the toolbar below).
                if let photo = store.selectedPhoto, !store.zoom.isZoomed {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(photo.displayName).font(.system(size: 13, weight: .medium))
                        if photo.hasEdits { Text("Edited").font(Theme.smallFont) }
                    }
                    .foregroundStyle(Theme.text)
                    .shadow(color: .black, radius: 2)
                    .padding(14)
                }
            }
    }

    private var neighbors: [Photo] {
        guard let id = store.selectedPhotoID else { return [] }
        return store.neighbors(of: id)
    }
}

/// Shows one photo large (with its edits), thumbnail first, then the sharp preview.
struct PhotoPane: View {
    let photo: Photo?
    var neighbors: [Photo] = []
    /// nil = no zooming (Compare).
    var zoom: Binding<ZoomLevel>?
    var clickZoom: ZoomLevel = .percent(100)
    /// Focus peaking on (with this sensitivity), or nil.
    var peaking: FocusPeaking.Sensitivity? = nil
    /// Changes when "Zoom to Sharpest Area" is asked for.
    var focusZoomToken = 0

    @State private var image: CGImage?
    /// Focus-peaked version of the shown image (and its sharpest point).
    @State private var peaked: (source: ObjectIdentifier, sensitivity: FocusPeaking.Sensitivity, result: FocusPeaking.Result)?
    @State private var zoomTarget: ZoomTarget?
    @State private var isPeaking = false
    @State private var fullImage: CGImage?
    @State private var failed = false
    /// Long side of the photo file in pixels (to size the preview while the full image loads).
    @State private var fileLongSide: CGFloat?

    private var zoomed: Bool { zoom?.wrappedValue.isZoomed ?? false }

    static let previewSize = 2560
    static let fullSize = 16384

    private struct LoadKey: Equatable {
        let id: Int64?
        let develop: DevelopSettings?
        let zoomed: Bool
    }

    var body: some View {
        ZStack {
            Theme.center
            if let zoom, let shown = fullImage ?? image {
                ZoomPanView(image: displayed(shown), contentScale: fullImage != nil ? 1 : previewScale(for: shown),
                            zoom: zoom, clickZoom: clickZoom, resetKey: photo?.id, margin: 24,
                            zoomTarget: zoomTarget)
                if zoomed && fullImage == nil {
                    ProgressView()
                        .controlSize(.small)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            } else if let image {
                Image(decorative: displayed(image), scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(24)
            } else if failed {
                Label("Can't open this photo", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .overlay(alignment: .topLeading) {
            if let zoom, zoom.wrappedValue.isZoomed {
                Text(zoom.wrappedValue.label)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .padding(12)
            }
        }
        .overlay(alignment: .topTrailing) {
            if peaking != nil {
                HStack(spacing: 5) {
                    if isPeaking { ProgressView().controlSize(.mini) }
                    Text("FOCUS").font(.caption.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                .padding(12)
                .help("Focus peaking: red = in focus (⇧F)")
            }
        }
        .task(id: LoadKey(id: photo?.id, develop: photo?.develop, zoomed: zoomed)) { await load() }
        .task(id: PeakKey(source: (fullImage ?? image).map { ObjectIdentifier($0) }, sensitivity: peaking)) {
            await updatePeaking()
        }
        .onChange(of: focusZoomToken) { _, token in
            Task { await zoomToSharpest(token: token) }
        }
    }

    private struct PeakKey: Equatable {
        let source: ObjectIdentifier?
        let sensitivity: FocusPeaking.Sensitivity?
    }

    /// The peaked image when focus peaking is on and ready for `shown`.
    private func displayed(_ shown: CGImage) -> CGImage {
        guard let peaking, let peaked, peaked.source == ObjectIdentifier(shown), peaked.sensitivity == peaking
        else { return shown }
        return peaked.result.image
    }

    private func updatePeaking() async {
        guard let peaking, let shown = fullImage ?? image else {
            isPeaking = false
            return
        }
        let id = ObjectIdentifier(shown)
        if let peaked, peaked.source == id, peaked.sensitivity == peaking { return }
        isPeaking = true
        let result = await Task.detached(priority: .userInitiated) {
            FocusPeaking.analyze(shown, sensitivity: peaking)
        }.value
        guard !Task.isCancelled else { return }
        isPeaking = false
        if let result { peaked = (id, peaking, result) }
    }

    /// Zoom to Sharpest Area (⇧Z): 100% on the area with the most fine detail.
    private func zoomToSharpest(token: Int) async {
        guard zoom != nil, let shown = image else { return }
        // Use the preview (the whole frame at a size that's quick to measure).
        let point: CGPoint?
        if let peaked, peaked.source == ObjectIdentifier(shown) {
            point = peaked.result.sharpest
        } else {
            point = await Task.detached(priority: .userInitiated) {
                FocusPeaking.analyze(shown, sensitivity: .medium)?.sharpest
            }.value
        }
        guard let point else { return }
        zoomTarget = ZoomTarget(point: point, id: token)
    }

    /// Full-resolution pixels per preview pixel (estimate until the full image arrives).
    private func previewScale(for preview: CGImage) -> CGFloat {
        let previewLong = CGFloat(max(preview.width, preview.height))
        guard var fullLong = fileLongSide, previewLong > 0 else { return 1 }
        if let crop = photo?.develop.crop, !crop.isDefault {
            fullLong *= max(crop.width, crop.height)
        }
        return max(1, fullLong / previewLong)
    }

    private func load() async {
        guard let photo else {
            image = nil
            return
        }
        failed = false
        fullImage = nil
        let quick = ImageLoader.shared.cachedDisplayImage(for: photo, maxPixel: ThumbnailDiskCache.maxPixel)
        if let quick { image = quick }
        let url = photo.url
        fileLongSide = await Task.detached(priority: .userInitiated) {
            ImageLoader.pixelLongSide(of: url)
        }.value
        if Task.isCancelled { return }
        let preview = await ImageLoader.shared.displayImage(for: photo, maxPixel: Self.previewSize)
        if Task.isCancelled { return }
        if let preview {
            image = preview
        } else if quick == nil {
            image = nil
            failed = true
        }
        if zoomed {
            fullImage = nil
            let full = await ImageLoader.shared.displayImage(for: photo, maxPixel: Self.fullSize)
            if Task.isCancelled { return }
            fullImage = full
        } else {
            fullImage = nil
        }
        // Prepare the next and previous photos so stepping through is instant.
        for neighbor in neighbors {
            Task(priority: .utility) {
                _ = await ImageLoader.shared.displayImage(for: neighbor, maxPixel: Self.previewSize)
            }
        }
    }
}

struct PhotoInfoBar: View {
    @EnvironmentObject private var store: LibraryStore
    let photo: Photo

    var body: some View {
        HStack(spacing: 14) {
            Text(photo.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
            if photo.isRaw {
                Text("RAW").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            Divider().frame(height: 16)
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { stars in
                    Button {
                        store.setRating(photo.rating == stars ? 0 : stars)
                    } label: {
                        Image(systemName: stars <= photo.rating ? "star.fill" : "star")
                            .foregroundStyle(stars <= photo.rating ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("\(stars) star\(stars == 1 ? "" : "s") (\(stars))")
                }
            }
            Divider().frame(height: 16)
            flagButton(.pick, symbol: "flag.fill", help: "Pick (P)")
            flagButton(.reject, symbol: "xmark.circle.fill", help: "Reject (X)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func flagButton(_ flag: Flag, symbol: String, help: String) -> some View {
        Button {
            store.setFlag(photo.flag == flag ? .unflagged : flag)
        } label: {
            Image(systemName: symbol)
                .foregroundStyle(photo.flag == flag ? (flag == .reject ? Color.red : Color.white) : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
