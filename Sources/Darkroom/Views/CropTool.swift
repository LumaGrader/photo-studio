import SwiftUI

enum CropAspect: String, CaseIterable, Identifiable {
    case original = "Original"
    case free = "Free"
    case square = "1 : 1"
    case fourFive = "4 : 5"
    case fiveSeven = "5 : 7"
    case twoThree = "2 : 3"
    case sixteenNine = "16 : 9"

    var id: String { rawValue }

    /// Long side ÷ short side (nil = original or free).
    var longOverShort: Double? {
        switch self {
        case .original, .free: return nil
        case .square: return 1
        case .fourFive: return 5.0 / 4
        case .fiveSeven: return 7.0 / 5
        case .twoThree: return 3.0 / 2
        case .sixteenNine: return 16.0 / 9
        }
    }
}

/// Crop tool state shared by the overlay and the panel.
final class CropToolState: ObservableObject {
    @Published var aspect: CropAspect = .original
    @Published var portrait = false

    /// Width ÷ height in pixels to keep, or nil for Free.
    func ratio(frame: CGSize) -> Double? {
        switch aspect {
        case .free: return nil
        case .original: return Double(frame.width / frame.height)
        default:
            let r = aspect.longOverShort ?? 1
            return portrait ? 1 / r : r
        }
    }
}

// MARK: - Overlay (drawn over the uncropped preview)

struct CropOverlay: View {
    @ObservedObject var session: DevelopSession
    @ObservedObject var tool: CropToolState
    /// Where the preview image is drawn inside this view.
    let imageRect: CGRect
    let frame: CGSize

    private enum DragMode { case move, corner(Int) }

    @State private var mode: DragMode?
    @State private var startCrop = CropSettings()

    private let handle: CGFloat = 16

    var body: some View {
        let c = session.settings.crop
        let rect = viewRect(c)
        ZStack {
            // Dim outside the crop.
            Path { path in
                path.addRect(imageRect)
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

            // Rule of thirds.
            Path { path in
                for i in 1...2 {
                    let t = CGFloat(i) / 3
                    path.move(to: CGPoint(x: rect.minX + rect.width * t, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.minX + rect.width * t, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * t))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * t))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)

            Rectangle()
                .path(in: rect)
                .stroke(Color.white, lineWidth: 1)

            ForEach(0..<4, id: \.self) { corner in
                let p = cornerPoint(corner, rect)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
                    .position(p)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in drag(value) }
                .onEnded { _ in mode = nil })
    }

    // MARK: - Geometry helpers

    private func viewRect(_ c: CropSettings) -> CGRect {
        CGRect(x: imageRect.minX + CGFloat(c.x) * imageRect.width,
               y: imageRect.minY + CGFloat(c.y) * imageRect.height,
               width: CGFloat(c.width) * imageRect.width,
               height: CGFloat(c.height) * imageRect.height)
    }

    /// 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left.
    private func cornerPoint(_ corner: Int, _ rect: CGRect) -> CGPoint {
        switch corner {
        case 0: return CGPoint(x: rect.minX, y: rect.minY)
        case 1: return CGPoint(x: rect.maxX, y: rect.minY)
        case 2: return CGPoint(x: rect.maxX, y: rect.maxY)
        default: return CGPoint(x: rect.minX, y: rect.maxY)
        }
    }

    private func drag(_ value: DragGesture.Value) {
        if mode == nil {
            startCrop = session.settings.crop
            let rect = viewRect(startCrop)
            if let corner = (0..<4).first(where: {
                let p = cornerPoint($0, rect)
                return hypot(p.x - value.startLocation.x, p.y - value.startLocation.y) <= handle
            }) {
                mode = .corner(corner)
            } else if rect.contains(value.startLocation) {
                mode = .move
            } else {
                return
            }
            session.beginEdit()
        }
        let dx = Double(value.translation.width / imageRect.width)
        let dy = Double(value.translation.height / imageRect.height)
        switch mode {
        case .move: move(dx: dx, dy: dy)
        case .corner(let corner): resize(corner: corner, location: value.location)
        case nil: break
        }
    }

    /// Moves the crop as far as it can go toward the pointer while staying on the photo.
    private func move(dx: Double, dy: Double) {
        func moved(_ t: Double) -> CropSettings {
            var c = startCrop
            c.x = min(max(startCrop.x + dx * t, 0), 1 - c.width)
            c.y = min(max(startCrop.y + dy * t, 0), 1 - c.height)
            return c
        }
        var best = startCrop
        if CropGeometry.fits(moved(1), frame: frame) {
            best = moved(1)
        } else {
            var lo = 0.0, hi = 1.0
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                if CropGeometry.fits(moved(mid), frame: frame) { lo = mid } else { hi = mid }
            }
            best = moved(lo)
        }
        session.set(\.crop, best)
    }

    /// Drags one corner; the opposite corner stays put. Keeps the aspect ratio if locked.
    private func resize(corner: Int, location: CGPoint) {
        let s = startCrop
        let anchorX = (corner == 0 || corner == 3) ? s.x + s.width : s.x
        let anchorY = (corner == 0 || corner == 1) ? s.y + s.height : s.y
        let px = Double((location.x - imageRect.minX) / imageRect.width)
        let py = Double((location.y - imageRect.minY) / imageRect.height)
        var w = max(0.03, abs(px - anchorX))
        var h = max(0.03, abs(py - anchorY))
        if let ratio = tool.ratio(frame: frame) {
            let frameRatio = Double(frame.width / frame.height)
            // Normalised height that gives `ratio` for this width: h = w · frameRatio / ratio.
            let hForW = w * frameRatio / ratio
            if hForW > h { h = hForW } else { w = h * ratio / frameRatio }
        }
        func rect(_ scale: Double) -> CropSettings {
            var c = s
            c.width = w * scale
            c.height = h * scale
            c.x = (corner == 0 || corner == 3) ? anchorX - c.width : anchorX
            c.y = (corner == 0 || corner == 1) ? anchorY - c.height : anchorY
            return c
        }
        var lo = 0.0, hi = 1.0
        if CropGeometry.fits(rect(1), frame: frame) {
            lo = 1
        } else {
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                if CropGeometry.fits(rect(mid), frame: frame) { lo = mid } else { hi = mid }
            }
        }
        let result = rect(lo)
        if result.width > 0.02, result.height > 0.02 { session.set(\.crop, result) }
    }
}

// MARK: - Panel

struct CropPanel: View {
    @ObservedObject var session: DevelopSession
    @ObservedObject var tool: CropToolState
    let frame: CGSize?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Aspect", selection: Binding(
                    get: { tool.aspect },
                    set: { tool.aspect = $0; applyAspect() })
                ) {
                    ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
                }
                Button {
                    tool.portrait.toggle()
                    applyAspect()
                } label: {
                    Image(systemName: tool.portrait ? "rectangle.portrait" : "rectangle")
                }
                .help("Portrait / landscape")
                .disabled(tool.aspect.longOverShort == nil || tool.aspect == .square)
            }

            DevelopSlider(
                title: "Straighten",
                value: Binding(
                    get: { session.settings.crop.angle },
                    set: { setAngle(($0 * 10).rounded() / 10) }),
                range: -45...45,
                format: { String(format: "%+.1f°", $0) },
                onReset: {
                    session.beginEdit()
                    setAngle(0)
                },
                onEditingChanged: { if $0 { session.beginEdit() } })

            HStack {
                Button {
                    rotate(by: -90)
                } label: {
                    Label("Rotate Left", systemImage: "rotate.left")
                }
                Button {
                    rotate(by: 90)
                } label: {
                    Label("Rotate Right", systemImage: "rotate.right")
                }
            }
            .controlSize(.small)

            HStack {
                Button("Reset") {
                    session.beginEdit()
                    tool.aspect = .original
                    session.set(\.crop, CropSettings())
                }
                .disabled(session.settings.crop.isDefault)
                Spacer()
                Button("Done") { session.setCropMode(false) }
                    .keyboardShortcut(.defaultAction)
            }
            Text("Drag inside the frame to move it, drag a corner to resize. R or Return when done.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func frameSize(for crop: CropSettings) -> CGSize? {
        frame.map { crop.frameSize(for: $0) }
    }

    private func applyAspect() {
        let c = session.settings.crop
        guard let frameSize = frameSize(for: c), let ratio = tool.ratio(frame: frameSize) else { return }
        session.beginEdit()
        session.set(\.crop, CropGeometry.centred(ratio: ratio, angle: c.angle, rotate90: c.rotate90, frame: frameSize))
    }

    /// Straightening keeps a full-size crop full (auto-fits); a custom crop shrinks only if it must.
    private func setAngle(_ angle: Double) {
        var c = session.settings.crop
        guard let frameSize = frameSize(for: c) else { return }
        let ratio = tool.ratio(frame: frameSize) ?? Double(frameSize.width / frameSize.height) * c.width / c.height
        let auto = CropGeometry.centred(ratio: ratio, angle: c.angle, rotate90: c.rotate90, frame: frameSize)
        let wasAuto = abs(auto.width - c.width) < 0.002 && abs(auto.height - c.height) < 0.002
            && abs(auto.x - c.x) < 0.002 && abs(auto.y - c.y) < 0.002
        c.angle = min(max(angle, -45), 45)
        c = wasAuto
            ? CropGeometry.centred(ratio: ratio, angle: c.angle, rotate90: c.rotate90, frame: frameSize)
            : CropGeometry.fitted(c, frame: frameSize)
        session.set(\.crop, c)
    }

    private func rotate(by degrees: Int) {
        guard let source = frame else { return }
        session.beginEdit()
        var c = session.settings.crop
        c.rotate90 = ((c.rotate90 + degrees) % 360 + 360) % 360
        let newFrame = c.frameSize(for: source)
        tool.portrait = newFrame.height > newFrame.width
        let ratio = tool.ratio(frame: newFrame) ?? Double(newFrame.width / newFrame.height)
        session.set(\.crop, CropGeometry.centred(ratio: ratio, angle: c.angle, rotate90: c.rotate90, frame: newFrame))
    }
}
