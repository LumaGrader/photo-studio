import SwiftUI
import AppKit

/// Lines, handles and the brush cursor drawn over the photo for the selected mask component.
struct MaskDecoration: View {
    let component: MaskComponent
    let mapper: FrameMapper
    let rect: CGRect
    let hover: CGPoint?
    let brush: BrushSettings
    let optionKey: Bool

    var body: some View {
        Canvas { context, _ in
            switch component.kind {
            case .linear: drawLinear(&context)
            case .radial: drawRadial(&context)
            case .brush: drawBrush(&context)
            default: break
            }
        }
        .shadow(color: .black.opacity(0.8), radius: 1)
    }

    private func view(_ p: MaskPoint) -> CGPoint { mapper.toView(p, in: rect) }

    /// Source-pixel offset (y down) → mask point.
    private func offset(_ p: MaskPoint, dx: Double, dy: Double) -> MaskPoint {
        MaskPoint(p.x + dx / Double(mapper.sourceSize.width), p.y + dy / Double(mapper.sourceSize.height))
    }

    private func pin(_ context: inout GraphicsContext, _ p: CGPoint, filled: Bool, size: CGFloat = 10) {
        let r = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
        context.fill(Path(ellipseIn: r), with: .color(filled ? .white : .black.opacity(0.4)))
        context.stroke(Path(ellipseIn: r), with: .color(.white), lineWidth: 1.5)
    }

    private func drawLinear(_ context: inout GraphicsContext) {
        let d = mapper.pixelDelta(component.start, component.end)
        let length = max(hypot(d.dx, d.dy), 1)
        let px = Double(-d.dy / length), py = Double(d.dx / length)
        let reach = Double(mapper.longSide) * 3
        func line(through p: MaskPoint, dashed: Bool) {
            var path = Path()
            path.move(to: view(offset(p, dx: -px * reach, dy: -py * reach)))
            path.addLine(to: view(offset(p, dx: px * reach, dy: py * reach)))
            context.stroke(path, with: .color(.white.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1, dash: dashed ? [5, 4] : []))
        }
        let middle = MaskPoint((component.start.x + component.end.x) / 2, (component.start.y + component.end.y) / 2)
        line(through: component.start, dashed: false)
        line(through: middle, dashed: true)
        line(through: component.end, dashed: false)
        pin(&context, view(component.start), filled: false, size: 8)
        pin(&context, view(component.end), filled: false, size: 8)
        pin(&context, view(middle), filled: true)
    }

    private func drawRadial(_ context: inout GraphicsContext) {
        let a = component.angle * .pi / 180
        let long = Double(mapper.longSide)
        func ellipse(scale: Double) -> Path {
            var path = Path()
            for i in 0...72 {
                let t = Double(i) / 72 * 2 * .pi
                let along = component.radiusX * scale * cos(t) * long
                let across = component.radiusY * scale * sin(t) * long
                let p = view(offset(component.center, dx: along * cos(a) - across * sin(a),
                                    dy: along * sin(a) + across * cos(a)))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            return path
        }
        context.stroke(ellipse(scale: 1), with: .color(.white.opacity(0.95)), lineWidth: 1.2)
        let inner = 1 - min(max(component.feather, 0), 100) / 100
        if inner > 0.02 {
            context.stroke(ellipse(scale: inner), with: .color(.white.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        for handle in radialHandles() {
            pin(&context, view(handle), filled: false, size: 7)
        }
        pin(&context, view(component.center), filled: true)
    }

    private func radialHandles() -> [MaskPoint] {
        let a = component.angle * .pi / 180
        let long = Double(mapper.longSide)
        return [(component.radiusX, 0.0), (-component.radiusX, 0.0), (0.0, component.radiusY), (0.0, -component.radiusY)]
            .map { along, across in
                offset(component.center, dx: (along * cos(a) - across * sin(a)) * long,
                       dy: (along * sin(a) + across * cos(a)) * long)
            }
    }

    private func drawBrush(_ context: inout GraphicsContext) {
        guard let hover else { return }
        let radius = CGFloat(brush.size) * mapper.longSide * mapper.viewScale(in: rect)
        let outer = CGRect(x: hover.x - radius, y: hover.y - radius, width: radius * 2, height: radius * 2)
        let erase = brush.erase || optionKey
        context.stroke(Path(ellipseIn: outer), with: .color(.white), lineWidth: 1.2)
        let innerRadius = radius * CGFloat(1 - brush.feather)
        if innerRadius > 2 {
            let inner = CGRect(x: hover.x - innerRadius, y: hover.y - innerRadius,
                               width: innerRadius * 2, height: innerRadius * 2)
            context.stroke(Path(ellipseIn: inner), with: .color(.white.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        // "−" in the middle while erasing, "+" while painting.
        var sign = Path()
        sign.move(to: CGPoint(x: hover.x - 4, y: hover.y))
        sign.addLine(to: CGPoint(x: hover.x + 4, y: hover.y))
        if !erase {
            sign.move(to: CGPoint(x: hover.x, y: hover.y - 4))
            sign.addLine(to: CGPoint(x: hover.x, y: hover.y + 4))
        }
        context.stroke(sign, with: .color(.white), lineWidth: 1.2)
    }
}

/// Lightroom-style Masking panel: create masks, pick components, local sliders.
struct MaskingPanel: View {
    @ObservedObject var session: DevelopSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                createMenu(title: "Create New Mask", mode: nil)
                Spacer()
                Button("Done") { session.toggleMasking() }
                    .controlSize(.small)
                    .help("Close masking (⇧W)")
            }
            if session.settings.masks.isEmpty {
                Text("Choose what to mask: the subject, the background, a brush, a gradient, or a range of tones or colours.")
                    .font(Theme.smallFont)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(session.settings.masks) { layer in
                maskRow(layer)
                if layer.id == session.selectedMaskID {
                    componentList(layer)
                }
            }
            if session.selectedMaskIndex != nil {
                Toggle("Show Overlay (O)", isOn: $session.showMaskOverlay)
                    .toggleStyle(.checkbox)
                    .font(Theme.bodyFont)
                componentOptions
                adjustments
            }
        }
    }

    // MARK: - Create

    private func createMenu(title: String, mode: MaskMode?) -> some View {
        Menu {
            Button("Subject") { create(.subject, mode: mode) }
            Button("Background") { create(.subject, mode: mode, invert: true) }
            Divider()
            Button("Brush (K)") { create(.brush, mode: mode) }
            Button("Linear Gradient (M)") { create(.linear, mode: mode) }
            Button("Radial Gradient (⇧M)") { create(.radial, mode: mode) }
            Divider()
            Button("Luminance Range") { create(.luminanceRange, mode: mode) }
            Button("Color Range") { create(.colorRange, mode: mode) }
        } label: {
            Label(title, systemImage: mode == .subtract ? "minus.circle" : (mode == .intersect ? "circle.circle" : "plus.circle"))
                .font(Theme.bodyFont)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .fixedSize()
    }

    private func create(_ kind: MaskKind, mode: MaskMode?, invert: Bool = false) {
        if let mode {
            session.addComponent(kind, mode: mode, invert: invert)
        } else {
            session.createMask(kind, invert: invert)
        }
    }

    // MARK: - Lists

    private func maskRow(_ layer: MaskLayer) -> some View {
        let selected = layer.id == session.selectedMaskID
        return HStack(spacing: 6) {
            Button {
                session.toggleMaskVisible(layer.id)
            } label: {
                Image(systemName: layer.visible ? "eye" : "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
            .help("Show / hide this mask's effect")
            Text(layer.name)
                .font(Theme.bodyFont.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.textBright : Theme.text)
            Spacer()
            if !layer.adjustments.isNeutral {
                Circle().fill(Theme.textDim).frame(width: 5, height: 5).help("Has adjustments")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(selected ? Theme.selection.opacity(0.6) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { session.selectMask(layer.id) }
        .contextMenu {
            Button("Duplicate") { session.duplicateMask(layer.id) }
            Button("Delete", role: .destructive) { session.deleteMask(layer.id) }
        }
    }

    @ViewBuilder
    private func componentList(_ layer: MaskLayer) -> some View {
        ForEach(Array(layer.components.enumerated()), id: \.element.id) { index, component in
            let selected = component.id == session.selectedComponentID
            HStack(spacing: 6) {
                Image(systemName: component.kind.systemImage)
                    .font(.system(size: 10))
                    .frame(width: 14)
                Text(index == 0 ? component.title : "\(component.mode.rawValue): \(component.title)")
                    .font(Theme.smallFont)
                    .lineLimit(1)
                if component.invert && component.kind != .subject {
                    Text("inverted").font(Theme.smallFont).foregroundStyle(Theme.textDim)
                }
                Spacer()
            }
            .foregroundStyle(selected ? Theme.textBright : Theme.textDim)
            .padding(.vertical, 3)
            .padding(.leading, 22)
            .padding(.trailing, 6)
            .background(selected ? Theme.selection.opacity(0.35) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
            .onTapGesture { session.selectComponent(maskID: layer.id, componentID: component.id) }
            .contextMenu {
                Button("Invert") { setInvert(!component.invert, componentID: component.id) }
                Button("Delete", role: .destructive) { session.deleteComponent(component.id) }
            }
        }
        HStack(spacing: 10) {
            createMenu(title: "Add", mode: .add)
            createMenu(title: "Subtract", mode: .subtract)
            createMenu(title: "Intersect", mode: .intersect)
        }
        .padding(.leading, 22)
    }

    private func setInvert(_ on: Bool, componentID: UUID) {
        guard let maskID = session.selectedMaskID else { return }
        session.beginEdit()
        session.updateComponent(maskID, componentID) { $0.invert = on }
    }

    // MARK: - Component options

    @ViewBuilder
    private var componentOptions: some View {
        if let maskID = session.selectedMaskID, let componentID = session.selectedComponentID,
           let component = session.component(maskID, componentID) {
            let ids = (maskID, componentID)
            let number: (Double) -> String = { "\(Int($0.rounded()))" }
            switch component.kind {
            case .brush:
                PanelSubheading(text: "Brush")
                Picker("Brush", selection: Binding(
                    get: { session.brush.erase },
                    set: { session.brush.erase = $0 })
                ) {
                    Text("Paint").tag(false)
                    Text("Erase").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                DevelopSlider(title: "Size", value: Binding(
                    get: { session.brush.size * 100 },
                    set: { session.brush.size = max(0.002, $0 / 100) }),
                    range: 0.2...30, format: { String(format: "%.1f", $0) },
                    onReset: { session.brush.size = BrushSettings().size }, onEditingChanged: { _ in })
                DevelopSlider(title: "Feather", value: Binding(
                    get: { session.brush.feather * 100 },
                    set: { session.brush.feather = $0 / 100 }),
                    range: 0...100, format: number,
                    onReset: { session.brush.feather = BrushSettings().feather }, onEditingChanged: { _ in })
                DevelopSlider(title: "Flow", value: Binding(
                    get: { session.brush.flow * 100 },
                    set: { session.brush.flow = max(0.02, $0 / 100) }),
                    range: 2...100, format: number,
                    onReset: { session.brush.flow = BrushSettings().flow }, onEditingChanged: { _ in })
                hint("Paint on the photo. Hold ⌥ Option to erase.")
            case .linear:
                hint("Drag on the photo to place the gradient: full effect where you start, none where you let go. Drag the dots to adjust.")
            case .radial:
                componentSlider("Feather", \.feather, ids: ids, range: 0...100, format: number, defaultValue: 50)
                componentSlider("Angle", \.angle, ids: ids, range: -90...90, format: number, defaultValue: 0)
                Toggle("Invert", isOn: Binding(
                    get: { component.invert },
                    set: { setInvert($0, componentID: component.id) }))
                    .toggleStyle(.checkbox)
                    .font(Theme.bodyFont)
                hint("Drag on the photo to draw an ellipse. Drag the centre to move it, the side dots to resize.")
            case .subject:
                hint(component.invert ? "Everything except the main subject (made by macOS)." : "The main subject, found by macOS.")
            case .luminanceRange:
                Button {
                    session.activePicker = session.activePicker == .maskLuminance ? nil : .maskLuminance
                } label: {
                    Label("Pick a Tone", systemImage: "eyedropper")
                        .font(Theme.bodyFont)
                }
                .controlSize(.small)
                componentSlider("From", \.lumLow, ids: ids, range: 0...1, format: { "\(Int(($0 * 100).rounded()))" }, defaultValue: 0.5)
                componentSlider("To", \.lumHigh, ids: ids, range: 0...1, format: { "\(Int(($0 * 100).rounded()))" }, defaultValue: 1)
                componentSlider("Smoothness", \.lumSmoothness, ids: ids, range: 0...0.5, format: { "\(Int(($0 * 200).rounded()))" }, defaultValue: 0.15)
            case .colorRange:
                HStack {
                    Button {
                        session.activePicker = session.activePicker == .maskColor ? nil : .maskColor
                    } label: {
                        Label(component.hasPickedColor ? "Pick Again" : "Pick a Colour", systemImage: "eyedropper")
                            .font(Theme.bodyFont)
                    }
                    .controlSize(.small)
                    if component.hasPickedColor {
                        let rgb = SRGBColor.fromOklab(component.pickL, component.pickA, component.pickB)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b))
                            .frame(width: 22, height: 16)
                    }
                    Spacer()
                }
                componentSlider("Refine", \.colorAmount, ids: ids, range: 0...100, format: number, defaultValue: 50)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Theme.smallFont)
            .foregroundStyle(Theme.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func componentSlider(
        _ title: String, _ path: WritableKeyPath<MaskComponent, Double>, ids: (UUID, UUID),
        range: ClosedRange<Double>, format: @escaping (Double) -> String, defaultValue: Double
    ) -> some View {
        DevelopSlider(
            title: title,
            value: Binding(
                get: { session.component(ids.0, ids.1)?[keyPath: path] ?? defaultValue },
                set: { value in session.updateComponent(ids.0, ids.1) { $0[keyPath: path] = value } }),
            range: range,
            format: format,
            onReset: {
                session.beginEdit()
                session.updateComponent(ids.0, ids.1) { $0[keyPath: path] = defaultValue }
            },
            onEditingChanged: { if $0 { session.beginEdit() } })
    }

    // MARK: - Local adjustments

    @ViewBuilder
    private var adjustments: some View {
        if let maskID = session.selectedMaskID, let layer = session.settings.masks.first(where: { $0.id == maskID }) {
            HStack {
                PanelSubheading(text: "Adjustments")
                Spacer()
                Button("Reset") { session.resetMaskAdjustments(maskID) }
                    .controlSize(.mini)
                    .disabled(layer.adjustments.isNeutral)
            }
            local("Temp", \.temperature, maskID)
            local("Tint", \.tint, maskID)
            local("Exposure", \.exposure, maskID, range: -4...4, format: { String(format: "%+.2f", $0) }, step: 0.01)
            local("Contrast", \.contrast, maskID)
            local("Highlights", \.highlights, maskID)
            local("Shadows", \.shadows, maskID)
            local("Whites", \.whites, maskID)
            local("Blacks", \.blacks, maskID)
            local("Texture", \.texture, maskID)
            local("Clarity", \.clarity, maskID)
            local("Dehaze", \.dehaze, maskID)
            local("Saturation", \.saturation, maskID)
            local("Sharpness", \.sharpness, maskID)
            PanelSubheading(text: "Color")
            local("Hue", \.colorHue, maskID, range: 0...360, format: { "\(Int($0.rounded()))°" })
            local("Amount", \.colorSaturation, maskID, range: 0...100, format: { "\(Int($0.rounded()))" })
        }
    }

    private func local(
        _ title: String, _ path: WritableKeyPath<LocalAdjustments, Double>, _ maskID: UUID,
        range: ClosedRange<Double> = -100...100,
        format: @escaping (Double) -> String = { $0 == 0 ? "0" : String(format: "%+.0f", $0) },
        step: Double = 1
    ) -> some View {
        DevelopSlider(
            title: title,
            value: Binding(
                get: { session.maskAdjustment(maskID, path) },
                set: { session.setMaskAdjustment(maskID, path, ($0 / step).rounded() * step) }),
            range: range,
            format: format,
            onReset: {
                session.beginEdit()
                session.setMaskAdjustment(maskID, path, 0)
            },
            onEditingChanged: { if $0 { session.beginEdit() } })
    }
}

/// sRGB (0…1, encoded) from Oklab, for swatches.
enum SRGBColor {
    static func fromOklab(_ l: Double, _ a: Double, _ b: Double) -> (r: Double, g: Double, b: Double) {
        let lin = Oklab.toLinear(SIMD3(l, a, b))
        func e(_ v: Double) -> Double { min(1, max(0, SRGB.encode(v))) }
        return (e(lin.x), e(lin.y), e(lin.z))
    }
}

/// Magnifier shown next to the cursor while a colour picker is active (WB, Point Color,
/// Color Mixer, mask ranges): the pixels around the cursor, enlarged, with their RGB.
struct PickerLoupe: View {
    let image: CGImage
    let rect: CGRect
    let hover: CGPoint

    private static let size: CGFloat = 124
    private static let span = 15 // photo pixels across

    var body: some View {
        if let content = content {
            let above = hover.y - Self.size / 2 - 28
            let y = above - Self.size / 2 > 4 ? above : hover.y + Self.size / 2 + 28
            VStack(spacing: 4) {
                ZStack {
                    Image(decorative: content.patch, scale: 1)
                        .resizable()
                        .interpolation(.none)
                    // The averaged sample area (7 × 7 pixels) in the middle.
                    Rectangle()
                        .stroke(Color.white, lineWidth: 1)
                        .frame(width: Self.size * 7 / CGFloat(Self.span), height: Self.size * 7 / CGFloat(Self.span))
                        .shadow(color: .black, radius: 1)
                }
                .frame(width: Self.size, height: Self.size)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
                .shadow(color: .black.opacity(0.6), radius: 4)
                Text(content.readout)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
            }
            .position(x: hover.x, y: y)
        }
    }

    private var content: (patch: CGImage, readout: String)? {
        guard rect.width > 0, rect.height > 0, rect.contains(hover) else { return nil }
        let u = (hover.x - rect.minX) / rect.width
        let v = (hover.y - rect.minY) / rect.height
        let span = Self.span
        let px = Int(u * CGFloat(image.width)), py = Int(v * CGFloat(image.height))
        let x0 = min(max(px - span / 2, 0), max(image.width - span, 0))
        let y0 = min(max(py - span / 2, 0), max(image.height - span, 0))
        guard let patch = image.cropping(to: CGRect(x: x0, y: y0, width: span, height: span)),
              let color = ImageSampler.average(image, at: CGPoint(x: u, y: v)) else { return nil }
        func pct(_ value: Double) -> String { String(format: "%.0f", value * 100) }
        return (patch, "R \(pct(color.x))  G \(pct(color.y))  B \(pct(color.z)) %")
    }
}
