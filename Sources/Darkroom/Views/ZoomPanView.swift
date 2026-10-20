import SwiftUI
import AppKit

/// Loupe / Develop zoom: Fit, or a percentage of the photo's real pixels
/// (100% = one photo pixel per screen pixel).
enum ZoomLevel: Hashable {
    case fit
    case percent(Double)

    static let minPercent = 5.0
    static let maxPercent = 800.0
    static let presets: [ZoomLevel] = [.fit, .percent(25), .percent(50), .percent(100), .percent(200), .percent(400)]

    var isZoomed: Bool { self != .fit }

    var label: String {
        switch self {
        case .fit: return "FIT"
        case .percent(let p): return "\(Int(p.rounded()))%"
        }
    }

    var menuLabel: String { self == .fit ? "Fit" : label }
}

/// A request to zoom in on a point of the photo (0…1 from the top-left). A new `id`
/// repeats the request for the same point.
struct ZoomTarget: Equatable {
    let point: CGPoint
    let id: Int
}

/// Shows a photo at Fit or a zoom level. Zoomed: drag (or two-finger scroll) to pan,
/// pinch to zoom, click to go back to Fit. At Fit, click zooms in on the clicked point.
struct ZoomPanView: View {
    let image: CGImage
    /// Real photo pixels per pixel of `image` (> 1 while a smaller preview stands in for the full render).
    var contentScale: CGFloat = 1
    @Binding var zoom: ZoomLevel
    /// Level used when clicking at Fit (the last chosen zoom).
    var clickZoom: ZoomLevel = .percent(100)
    /// Pan resets when this changes (a different photo).
    var resetKey: AnyHashable?
    var margin: CGFloat = 28
    /// When set, clicks and drags go to this tool instead of zoom/pan: phase, point on the
    /// photo (0…1 from the top-left) and drag distance in points.
    var onPick: ((PickPhase, CGPoint, CGSize) -> Void)? = nil
    /// Like `onPick`, with the view location and the photo's rectangle (mask editing).
    var onPointer: ((PointerEvent) -> Void)? = nil
    /// Drawn over the photo (not clickable), given the photo's rectangle in the view.
    var decoration: ((CGRect) -> AnyView)? = nil
    /// Mouse position over the view while a tool is active (nil = left).
    var onHover: ((CGPoint?) -> Void)? = nil
    /// Zoom to 100% (or the click zoom, if bigger) centred on this point.
    var zoomTarget: ZoomTarget? = nil

    @State private var picking = false
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var pinchStart: (percent: Double, offset: CGSize)?
    @State private var viewFrame: CGRect = .zero
    @State private var scrollMonitor: Any?

    private var backingScale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }

    /// Size of the full-resolution photo in pixels.
    private var photoPixels: CGSize {
        CGSize(width: CGFloat(image.width) * contentScale, height: CGFloat(image.height) * contentScale)
    }

    var body: some View {
        GeometryReader { geometry in
            let viewSize = geometry.size
            let rect = displayRect(in: viewSize)
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(currentPercent(in: viewSize) > 150 ? .none : .high)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                // Zoom changes glide instead of jumping (not while pinching, which already follows the fingers).
                .animation(pinchStart == nil ? .easeOut(duration: 0.18) : nil, value: zoom)
                .shadow(color: .black.opacity(0.5), radius: zoom.isZoomed ? 0 : 6)
                .frame(width: viewSize.width, height: viewSize.height)
                .contentShape(Rectangle())
                .clipped()
                .gesture(dragGesture(viewSize: viewSize))
                .simultaneousGesture(magnifyGesture(viewSize: viewSize))
                .onTapGesture(coordinateSpace: .local) { location in
                    tap(at: location, viewSize: viewSize)
                }
                .overlay {
                    if let decoration {
                        decoration(rect).allowsHitTesting(false)
                    }
                }
                .overlay {
                    if onPick != nil || onPointer != nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(pickGesture(viewSize: viewSize))
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    NSCursor.crosshair.set()
                                    onHover?(location)
                                case .ended:
                                    NSCursor.arrow.set()
                                    onHover?(nil)
                                }
                            }
                            .onDisappear { NSCursor.arrow.set() }
                    }
                }
                .onAppear { viewFrame = geometry.frame(in: .global) }
                .onChange(of: geometry.frame(in: .global)) { _, frame in
                    viewFrame = frame
                    offset = clamped(offset, viewSize: frame.size)
                }
                .onChange(of: zoom) { _, level in
                    if level == .fit {
                        offset = .zero
                    } else if pinchStart == nil {
                        offset = clamped(offset, viewSize: viewSize)
                    }
                }
        }
        .onChange(of: resetKey) { _, _ in offset = .zero }
        .onChange(of: zoomTarget) { _, target in
            guard let target else { return }
            zoom(to: target.point)
        }
        .onAppear(perform: installScrollMonitor)
        .onDisappear(perform: removeScrollMonitor)
    }

    // MARK: - Geometry

    private func fitPercent(in viewSize: CGSize) -> Double {
        let available = CGSize(width: max(1, viewSize.width - 2 * margin), height: max(1, viewSize.height - 2 * margin))
        let pixels = photoPixels
        guard pixels.width > 0, pixels.height > 0 else { return 100 }
        let points = min(available.width / pixels.width, available.height / pixels.height)
        return Double(points * backingScale * 100)
    }

    private func currentPercent(in viewSize: CGSize) -> Double {
        switch zoom {
        case .fit: return fitPercent(in: viewSize)
        case .percent(let p): return p
        }
    }

    /// Size of the photo on screen, in points.
    private func contentSize(percent: Double) -> CGSize {
        let pixels = photoPixels
        let k = CGFloat(percent / 100) / backingScale
        return CGSize(width: pixels.width * k, height: pixels.height * k)
    }

    private func displayRect(in viewSize: CGSize) -> CGRect {
        let size = contentSize(percent: currentPercent(in: viewSize))
        let o = zoom.isZoomed ? offset : .zero
        return CGRect(x: (viewSize.width - size.width) / 2 + o.width,
                      y: (viewSize.height - size.height) / 2 + o.height,
                      width: size.width, height: size.height)
    }

    /// Keeps the photo covering the view (or centred when it is smaller).
    private func clamped(_ o: CGSize, viewSize: CGSize, percent: Double? = nil) -> CGSize {
        let size = contentSize(percent: percent ?? currentPercent(in: viewSize))
        let maxX = max(0, (size.width - viewSize.width) / 2)
        let maxY = max(0, (size.height - viewSize.height) / 2)
        return CGSize(width: min(max(o.width, -maxX), maxX), height: min(max(o.height, -maxY), maxY))
    }

    /// Changes the zoom so the photo point under `anchor` stays under it.
    private func setPercent(_ percent: Double, keeping anchor: CGPoint, viewSize: CGSize,
                            from start: (percent: Double, offset: CGSize)? = nil, snapToFit: Bool = false) {
        let newPercent = min(max(percent, ZoomLevel.minPercent), ZoomLevel.maxPercent)
        let oldPercent = start?.percent ?? currentPercent(in: viewSize)
        let oldOffset = start?.offset ?? (zoom.isZoomed ? offset : .zero)
        let oldSize = contentSize(percent: oldPercent)
        let newSize = contentSize(percent: newPercent)
        let centre = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        // Position of the anchor inside the photo, 0…1.
        let u = (anchor.x - centre.x - oldOffset.width) / max(oldSize.width, 1) + 0.5
        let v = (anchor.y - centre.y - oldOffset.height) / max(oldSize.height, 1) + 0.5
        let next = CGSize(width: anchor.x - centre.x - (u - 0.5) * newSize.width,
                          height: anchor.y - centre.y - (v - 0.5) * newSize.height)
        offset = clamped(next, viewSize: viewSize, percent: newPercent)
        zoom = newPercent <= fitPercent(in: viewSize) + 0.01 && (start != nil || snapToFit) ? .fit : .percent(newPercent)
    }

    /// Zooms in with `point` (0…1 of the photo) in the middle of the view.
    private func zoom(to point: CGPoint) {
        let viewSize = viewFrame.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        var percent = 100.0
        if case .percent(let p) = clickZoom, p > percent { percent = p }
        let size = contentSize(percent: percent)
        let next = CGSize(width: -(point.x - 0.5) * size.width, height: -(point.y - 0.5) * size.height)
        offset = clamped(next, viewSize: viewSize, percent: percent)
        zoom = .percent(percent)
    }

    // MARK: - Gestures

    private func tap(at location: CGPoint, viewSize: CGSize) {
        if zoom.isZoomed {
            zoom = .fit
            return
        }
        let rect = displayRect(in: viewSize)
        guard rect.contains(location) else { return }
        guard case .percent(let target) = clickZoom else { return }
        setPercent(target, keeping: location, viewSize: viewSize)
    }

    private func pickGesture(viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let rect = displayRect(in: viewSize)
                guard rect.width > 0, rect.height > 0 else { return }
                let point = CGPoint(x: min(max((value.location.x - rect.minX) / rect.width, 0), 1),
                                    y: min(max((value.location.y - rect.minY) / rect.height, 0), 1))
                // Mask tools may start just outside the photo (e.g. a gradient from the edge).
                let unclamped = CGPoint(x: (value.location.x - rect.minX) / rect.width,
                                        y: (value.location.y - rect.minY) / rect.height)
                let phase: PickPhase
                if !picking {
                    guard rect.insetBy(dx: -24, dy: -24).contains(value.startLocation) else { return }
                    picking = true
                    phase = .began
                } else {
                    phase = .changed
                }
                if onPick != nil, phase == .changed || rect.contains(value.startLocation) {
                    onPick?(phase, point, phase == .began ? .zero : value.translation)
                }
                onPointer?(PointerEvent(phase: phase, point: unclamped, location: value.location,
                                        rect: rect, translation: value.translation))
            }
            .onEnded { value in
                guard picking else { return }
                picking = false
                let rect = displayRect(in: viewSize)
                onPick?(.ended, .zero, value.translation)
                onPointer?(PointerEvent(phase: .ended,
                                        point: CGPoint(x: (value.location.x - rect.minX) / max(rect.width, 1),
                                                       y: (value.location.y - rect.minY) / max(rect.height, 1)),
                                        location: value.location, rect: rect, translation: value.translation))
            }
    }

    private func dragGesture(viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard zoom.isZoomed else { return }
                let start = dragStart ?? offset
                if dragStart == nil { dragStart = offset }
                offset = clamped(CGSize(width: start.width + value.translation.width,
                                        height: start.height + value.translation.height),
                                 viewSize: viewSize)
                NSCursor.closedHand.set()
            }
            .onEnded { _ in
                dragStart = nil
                NSCursor.arrow.set()
            }
    }

    private func magnifyGesture(viewSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStart == nil {
                    pinchStart = (currentPercent(in: viewSize), zoom.isZoomed ? offset : .zero)
                }
                guard let start = pinchStart else { return }
                let anchor = CGPoint(x: value.startAnchor.x * viewSize.width, y: value.startAnchor.y * viewSize.height)
                setPercent(start.percent * Double(value.magnification), keeping: anchor, viewSize: viewSize, from: start)
            }
            .onEnded { _ in pinchStart = nil }
    }

    // MARK: - Scroll: mouse wheel zooms, trackpad scroll pans

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let window = event.window, let content = window.contentView else { return event }
            // SwiftUI global coordinates are top-left based; AppKit window coordinates bottom-left.
            let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            guard viewFrame.contains(point) else { return event }
            let size = viewFrame.size
            let anchor = CGPoint(x: point.x - viewFrame.minX, y: point.y - viewFrame.minY)

            // Mouse wheel, or ⌘/⌥ + trackpad scroll: zoom around the cursor.
            let modifiers = event.modifierFlags
            if !event.hasPreciseScrollingDeltas || modifiers.contains(.command) || modifiers.contains(.option) {
                var dy = Double(event.scrollingDeltaY)
                if event.isDirectionInvertedFromDevice { dy = -dy }
                guard dy != 0 else { return nil }
                // Small steps (about 9% per wheel notch) so zoom grows gradually from Fit.
                let step = event.hasPreciseScrollingDeltas ? min(max(dy * 0.006, -0.15), 0.15) : min(max(dy, -1.5), 1.5) * 0.125
                setPercent(currentPercent(in: size) * pow(2, step), keeping: anchor, viewSize: size, snapToFit: true)
                return nil
            }

            // Trackpad two-finger scroll pans a zoomed photo.
            guard zoom.isZoomed else { return event }
            let next = CGSize(width: offset.width + event.scrollingDeltaX, height: offset.height + event.scrollingDeltaY)
            offset = clamped(next, viewSize: size)
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }
}

enum PickPhase {
    case began, changed, ended
}

/// A click or drag on the photo for mask tools.
struct PointerEvent {
    let phase: PickPhase
    /// 0…1 from the photo's top-left (may be slightly outside).
    let point: CGPoint
    /// In the view.
    let location: CGPoint
    /// The photo's rectangle in the view.
    let rect: CGRect
    let translation: CGSize
}

/// Zoom picker for toolbars: shows the level, opens Fit / 25% … 400%.
struct ZoomMenu: View {
    @Binding var zoom: ZoomLevel
    var onPick: (ZoomLevel) -> Void = { _ in }

    var body: some View {
        Menu {
            ForEach(ZoomLevel.presets, id: \.self) { level in
                Button(level.menuLabel) { onPick(level) }
            }
        } label: {
            Text(zoom.label)
                .font(Theme.smallFont.weight(.semibold))
                .monospacedDigit()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Zoom (Z toggles Fit and the last zoom level)")
    }
}
