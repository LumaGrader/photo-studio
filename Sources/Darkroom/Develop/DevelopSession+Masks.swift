import Foundation
import CoreGraphics

/// Maps between the shown (cropped, straightened) photo and the uncropped frame the
/// masks live in. Both as 0…1 from the top-left.
struct FrameMapper {
    let sourceSize: CGSize
    private let transform: CGAffineTransform
    private let cropRect: CGRect

    init(sourceSize: CGSize, crop c: CropSettings) {
        self.sourceSize = sourceSize
        if c.isDefault {
            transform = .identity
            cropRect = CGRect(origin: .zero, size: sourceSize)
        } else {
            // Same as DevelopRenderer.applyGeometry (Core Image coordinates, y up).
            let frame = c.frameSize(for: sourceSize)
            let radians = -(Double(c.rotate90) + c.angle) * .pi / 180
            transform = CGAffineTransform(translationX: -sourceSize.width / 2, y: -sourceSize.height / 2)
                .concatenating(CGAffineTransform(rotationAngle: CGFloat(radians)))
                .concatenating(CGAffineTransform(translationX: frame.width / 2, y: frame.height / 2))
            cropRect = CGRect(x: c.x * frame.width, y: (1 - c.y - c.height) * frame.height,
                              width: c.width * frame.width, height: c.height * frame.height)
        }
    }

    /// Size of the shown photo in source pixels.
    var finalPixelSize: CGSize { cropRect.size }
    var longSide: CGFloat { max(sourceSize.width, sourceSize.height) }

    func toSource(_ f: CGPoint) -> CGPoint {
        let inFrame = CGPoint(x: cropRect.minX + f.x * cropRect.width, y: cropRect.minY + (1 - f.y) * cropRect.height)
        let s = inFrame.applying(transform.inverted())
        return CGPoint(x: s.x / sourceSize.width, y: 1 - s.y / sourceSize.height)
    }

    func toFinal(_ p: CGPoint) -> CGPoint {
        let s = CGPoint(x: p.x * sourceSize.width, y: (1 - p.y) * sourceSize.height).applying(transform)
        return CGPoint(x: (s.x - cropRect.minX) / cropRect.width, y: 1 - (s.y - cropRect.minY) / cropRect.height)
    }

    /// A mask point in view coordinates, for a photo drawn in `rect`.
    func toView(_ p: MaskPoint, in rect: CGRect) -> CGPoint {
        let f = toFinal(p.cgPoint)
        return CGPoint(x: rect.minX + f.x * rect.width, y: rect.minY + f.y * rect.height)
    }

    /// View points per source pixel.
    func viewScale(in rect: CGRect) -> CGFloat {
        finalPixelSize.width > 0 ? rect.width / finalPixelSize.width : 1
    }

    /// Source pixels between two mask points (y down).
    func pixelDelta(_ a: MaskPoint, _ b: MaskPoint) -> CGVector {
        CGVector(dx: (b.x - a.x) * sourceSize.width, dy: (b.y - a.y) * sourceSize.height)
    }
}

/// What a drag on the photo is doing to the selected mask component.
enum MaskDragState {
    case brush
    case linearNew
    case linearStart
    case linearEnd
    case linearMove(start: MaskPoint, end: MaskPoint, origin: MaskPoint)
    case radialNew(origin: MaskPoint)
    case radialMove(center: MaskPoint, origin: MaskPoint)
    case radialX
    case radialY
}

extension DevelopSession {
    // MARK: - Lookup

    var selectedMaskIndex: Int? {
        settings.masks.firstIndex { $0.id == selectedMaskID }
    }

    var selectedComponentIndex: (mask: Int, component: Int)? {
        guard let m = selectedMaskIndex,
              let c = settings.masks[m].components.firstIndex(where: { $0.id == selectedComponentID })
        else { return nil }
        return (m, c)
    }

    var selectedComponent: MaskComponent? {
        selectedComponentIndex.map { settings.masks[$0.mask].components[$0.component] }
    }

    /// The selected component is drawn on the photo (brush, gradients).
    var isEditingDrawnMask: Bool {
        maskingOpen && !cropMode && activePicker == nil && (selectedComponent?.kind.isDrawn ?? false)
    }

    var frameMapper: FrameMapper? {
        sourceSize.map { FrameMapper(sourceSize: $0, crop: settings.crop) }
    }

    // MARK: - Masks

    func toggleMasking() {
        guard photo != nil, !cropMode else { return }
        activePicker = nil
        healingOpen = false
        maskingOpen.toggle()
    }

    /// "Done" for Masking and Healing: used when another Develop section is opened, like
    /// Lightroom (the masks and spots stay; only the tool closes).
    func finishTools() {
        guard maskingOpen || healingOpen else { return }
        activePicker = nil
        if maskingOpen { maskingOpen = false }
        if healingOpen {
            healingOpen = false
            spotDrag = nil
            selectedSpotID = nil
        }
    }

    /// New mask with one component. Subject + `invert` = Background.
    func createMask(_ kind: MaskKind, invert: Bool = false) {
        guard photo != nil else { return }
        if cropMode { setCropMode(false) }
        healingOpen = false
        maskingOpen = true
        var component = MaskComponent(kind: kind)
        component.invert = invert
        let number = (settings.masks.count + 1)
        let layer = MaskLayer(name: "Mask \(number)", components: [component])
        beginEdit()
        set(\.masks, settings.masks + [layer])
        selectedMaskID = layer.id
        selectedComponentID = component.id
        if kind == .colorRange { activePicker = .maskColor }
        if kind == .luminanceRange { activePicker = .maskLuminance }
    }

    /// Adds a component to the selected mask.
    func addComponent(_ kind: MaskKind, mode: MaskMode, invert: Bool = false) {
        guard let m = selectedMaskIndex else {
            createMask(kind, invert: invert)
            return
        }
        var component = MaskComponent(kind: kind, mode: mode)
        component.invert = invert
        beginEdit()
        set(\.masks[m].components, settings.masks[m].components + [component])
        selectedComponentID = component.id
        if kind == .colorRange { activePicker = .maskColor }
        if kind == .luminanceRange { activePicker = .maskLuminance }
    }

    func deleteMask(_ id: UUID) {
        guard let index = settings.masks.firstIndex(where: { $0.id == id }) else { return }
        beginEdit()
        var masks = settings.masks
        masks.remove(at: index)
        set(\.masks, masks)
        if selectedMaskID == id {
            selectedMaskID = masks.last?.id
            selectedComponentID = masks.last?.components.last?.id
        }
    }

    func duplicateMask(_ id: UUID) {
        guard let index = settings.masks.firstIndex(where: { $0.id == id }) else { return }
        var copy = settings.masks[index]
        copy.id = UUID()
        copy.name += " copy"
        copy.components = copy.components.map { component in
            var c = component
            c.id = UUID()
            return c
        }
        beginEdit()
        var masks = settings.masks
        masks.insert(copy, at: index + 1)
        set(\.masks, masks)
        selectedMaskID = copy.id
        selectedComponentID = copy.components.last?.id
    }

    func deleteComponent(_ id: UUID) {
        guard let m = selectedMaskIndex,
              let c = settings.masks[m].components.firstIndex(where: { $0.id == id }) else { return }
        beginEdit()
        if settings.masks[m].components.count == 1 {
            deleteMask(settings.masks[m].id)
            return
        }
        var components = settings.masks[m].components
        components.remove(at: c)
        set(\.masks[m].components, components)
        if selectedComponentID == id { selectedComponentID = components.last?.id }
    }

    func selectMask(_ id: UUID) {
        selectedMaskID = id
        selectedComponentID = settings.masks.first { $0.id == id }?.components.last?.id
        activePicker = nil
    }

    func selectComponent(maskID: UUID, componentID: UUID) {
        selectedMaskID = maskID
        selectedComponentID = componentID
        activePicker = nil
    }

    func toggleMaskVisible(_ id: UUID) {
        guard let index = settings.masks.firstIndex(where: { $0.id == id }) else { return }
        beginEdit()
        set(\.masks[index].visible, !settings.masks[index].visible)
    }

    /// Picks the Color Range colour from the shown photo (point 0…1 from the top-left).
    func pickMaskColor(at point: CGPoint) {
        guard let maskID = selectedMaskID, let componentID = selectedComponentID, let image,
              let color = ImageSampler.average(image, at: point) else { return }
        let lab = Oklab.fromLinear(SRGB.decode(color))
        beginEdit()
        updateComponent(maskID, componentID) { c in
            c.pickL = lab.x
            c.pickA = lab.y
            c.pickB = lab.z
            c.hasPickedColor = true
        }
    }

    // MARK: - Drawing on the photo

    func maskPointer(_ event: PointerEvent, optionKey: Bool) {
        guard let index = selectedComponentIndex, let mapper = frameMapper else { return }
        let m = index.mask, c = index.component
        var component = settings.masks[m].components[c]
        let p = MaskPoint(mapper.toSource(event.point))
        let hit: CGFloat = 12

        func near(_ q: MaskPoint) -> Bool {
            let v = mapper.toView(q, in: event.rect)
            return hypot(v.x - event.location.x, v.y - event.location.y) <= hit
        }

        switch event.phase {
        case .began:
            beginEdit()
            switch component.kind {
            case .brush:
                var stroke = BrushStroke()
                stroke.points = [rounded(p)]
                stroke.radius = brush.size
                stroke.feather = brush.feather
                stroke.flow = brush.flow
                stroke.erase = brush.erase || optionKey
                component.strokes.append(stroke)
                maskDrag = .brush
            case .linear:
                let middle = MaskPoint((component.start.x + component.end.x) / 2, (component.start.y + component.end.y) / 2)
                if near(component.start) {
                    maskDrag = .linearStart
                } else if near(component.end) {
                    maskDrag = .linearEnd
                } else if near(middle) {
                    maskDrag = .linearMove(start: component.start, end: component.end, origin: p)
                } else {
                    component.start = p
                    component.end = p
                    maskDrag = .linearNew
                }
            case .radial:
                let handles = radialHandles(component, mapper: mapper)
                if near(component.center) {
                    maskDrag = .radialMove(center: component.center, origin: p)
                } else if handles.x.contains(where: near) {
                    maskDrag = .radialX
                } else if handles.y.contains(where: near) {
                    maskDrag = .radialY
                } else {
                    component.center = p
                    component.radiusX = 0.01
                    component.radiusY = 0.01
                    component.angle = 0
                    maskDrag = .radialNew(origin: p)
                }
            default:
                return
            }

        case .changed:
            guard let drag = maskDrag else { return }
            switch drag {
            case .brush:
                guard var stroke = component.strokes.last, let last = stroke.points.last else { return }
                let d = mapper.pixelDelta(last, p)
                guard hypot(d.dx, d.dy) >= stroke.radius * mapper.longSide * 0.2 else { return }
                stroke.points.append(rounded(p))
                component.strokes[component.strokes.count - 1] = stroke
            case .linearNew, .linearEnd:
                component.end = p
            case .linearStart:
                component.start = p
            case let .linearMove(start, end, origin):
                let dx = p.x - origin.x, dy = p.y - origin.y
                component.start = MaskPoint(start.x + dx, start.y + dy)
                component.end = MaskPoint(end.x + dx, end.y + dy)
            case let .radialNew(origin):
                let d = mapper.pixelDelta(origin, p)
                component.radiusX = max(0.005, Double(abs(d.dx) / mapper.longSide))
                component.radiusY = max(0.005, Double(abs(d.dy) / mapper.longSide))
            case let .radialMove(center, origin):
                component.center = MaskPoint(center.x + p.x - origin.x, center.y + p.y - origin.y)
            case .radialX, .radialY:
                let d = mapper.pixelDelta(component.center, p)
                let a = component.angle * .pi / 180
                let along: CGFloat
                if case .radialX = drag {
                    along = d.dx * CGFloat(cos(a)) + d.dy * CGFloat(sin(a))
                    component.radiusX = max(0.005, Double(abs(along) / mapper.longSide))
                } else {
                    along = -d.dx * CGFloat(sin(a)) + d.dy * CGFloat(cos(a))
                    component.radiusY = max(0.005, Double(abs(along) / mapper.longSide))
                }
            }

        case .ended:
            guard let drag = maskDrag else { return }
            maskDrag = nil
            switch drag {
            case .linearNew:
                // A click without a drag: make a usable default gradient there.
                let d = mapper.pixelDelta(component.start, component.end)
                if hypot(d.dx, d.dy) < 4 {
                    component.end = MaskPoint(component.start.x, component.start.y + 0.25)
                }
            case .radialNew:
                if component.radiusX < 0.02 && component.radiusY < 0.02 {
                    component.radiusX = 0.15
                    component.radiusY = 0.12
                }
            default:
                return
            }
        }
        set(\.masks[m].components[c], component)
    }

    /// Edge handles of a radial gradient: ±x and ±y along its axes.
    func radialHandles(_ c: MaskComponent, mapper: FrameMapper) -> (x: [MaskPoint], y: [MaskPoint]) {
        let a = c.angle * .pi / 180
        let long = Double(mapper.longSide)
        let w = Double(mapper.sourceSize.width), h = Double(mapper.sourceSize.height)
        func point(_ along: Double, _ across: Double) -> MaskPoint {
            let dx = along * cos(a) - across * sin(a)
            let dy = along * sin(a) + across * cos(a)
            return MaskPoint(c.center.x + dx * long / w, c.center.y + dy * long / h)
        }
        return ([point(c.radiusX, 0), point(-c.radiusX, 0)], [point(0, c.radiusY), point(0, -c.radiusY)])
    }

    private func rounded(_ p: MaskPoint) -> MaskPoint {
        MaskPoint((p.x * 100_000).rounded() / 100_000, (p.y * 100_000).rounded() / 100_000)
    }
}

// MARK: - Safe access by ID
//
// Views bind sliders by mask / component / swatch ID, never by array index: after a delete
// or an undo SwiftUI may still read a binding of a row that is about to disappear, and an
// index that no longer exists would crash.

extension DevelopSession {
    func maskAdjustment(_ maskID: UUID, _ path: WritableKeyPath<LocalAdjustments, Double>) -> Double {
        settings.masks.first { $0.id == maskID }?.adjustments[keyPath: path] ?? 0
    }

    func setMaskAdjustment(_ maskID: UUID, _ path: WritableKeyPath<LocalAdjustments, Double>, _ value: Double) {
        guard let m = settings.masks.firstIndex(where: { $0.id == maskID }) else { return }
        set((\DevelopSettings.masks[m].adjustments).appending(path: path), value)
    }

    func resetMaskAdjustments(_ maskID: UUID) {
        guard let m = settings.masks.firstIndex(where: { $0.id == maskID }) else { return }
        beginEdit()
        set(\.masks[m].adjustments, LocalAdjustments())
    }

    func component(_ maskID: UUID, _ componentID: UUID) -> MaskComponent? {
        settings.masks.first { $0.id == maskID }?.components.first { $0.id == componentID }
    }

    func updateComponent(_ maskID: UUID, _ componentID: UUID, _ change: (inout MaskComponent) -> Void) {
        guard let m = settings.masks.firstIndex(where: { $0.id == maskID }),
              let c = settings.masks[m].components.firstIndex(where: { $0.id == componentID }) else { return }
        var component = settings.masks[m].components[c]
        change(&component)
        set(\.masks[m].components[c], component)
    }

    func pointColorValue(_ id: UUID, _ path: WritableKeyPath<PointColor, Double>) -> Double {
        settings.pointColors.first { $0.id == id }?[keyPath: path] ?? 0
    }

    func setPointColorValue(_ id: UUID, _ path: WritableKeyPath<PointColor, Double>, _ value: Double) {
        guard let i = settings.pointColors.firstIndex(where: { $0.id == id }) else { return }
        set((\DevelopSettings.pointColors[i]).appending(path: path), value)
    }

    /// Luminance Range from a click: the band around the picked tone.
    func pickMaskLuminance(at point: CGPoint) {
        guard let maskID = selectedMaskID, let componentID = selectedComponentID, let image,
              let color = ImageSampler.average(image, at: point) else { return }
        let linear = SRGB.decode(color)
        let tone = SRGB.encode(0.2126 * linear.x + 0.7152 * linear.y + 0.0722 * linear.z)
        beginEdit()
        updateComponent(maskID, componentID) { c in
            c.lumLow = max(0, tone - 0.15)
            c.lumHigh = min(1, tone + 0.15)
        }
    }
}
