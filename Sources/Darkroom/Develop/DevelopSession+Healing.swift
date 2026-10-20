import Foundation
import CoreGraphics

/// What a drag on the photo is doing with the Healing tool.
enum SpotDragState {
    /// A new spot: dragging sets its size.
    case new(center: MaskPoint, resized: Bool)
    case moveSpot(origin: MaskPoint, center: MaskPoint)
    case moveSource(origin: MaskPoint, source: MaskPoint)
}

/// Healing panel sliders: they change the selected spot, and the settings for new spots.
enum SpotField {
    case size, feather, opacity
}

extension DevelopSession {
    /// Clicks on the photo place and edit spots.
    var isHealing: Bool { healingOpen && !cropMode && activePicker == nil }

    var selectedSpot: SpotEdit? { settings.spots.first { $0.id == selectedSpotID } }

    func toggleHealing() {
        guard photo != nil else { return }
        if cropMode { setCropMode(false) }
        activePicker = nil
        maskingOpen = false
        healingOpen.toggle()
        spotDrag = nil
        if !healingOpen { selectedSpotID = nil }
    }

    // MARK: - Panel

    /// Size slider 1…100 ↔ radius 0.2 % … 15 % of the long side (finer at the small end).
    static func spotRadius(fromSize size: Double) -> Double {
        let t = min(max(size, 1), 100) / 100
        return 0.002 + t * t * 0.148
    }

    static func spotSize(fromRadius radius: Double) -> Double {
        (sqrt(max(radius - 0.002, 0) / 0.148) * 100).rounded()
    }

    func spotSetting(_ field: SpotField) -> Double {
        let radius = selectedSpot?.radius ?? spotDefaults.radius
        switch field {
        case .size: return Self.spotSize(fromRadius: radius)
        case .feather: return selectedSpot?.feather ?? spotDefaults.feather
        case .opacity: return selectedSpot?.opacity ?? spotDefaults.opacity
        }
    }

    func setSpotSetting(_ field: SpotField, _ value: Double) {
        switch field {
        case .size: spotDefaults.radius = Self.spotRadius(fromSize: value)
        case .feather: spotDefaults.feather = value
        case .opacity: spotDefaults.opacity = value
        }
        guard let id = selectedSpotID else { return }
        updateSpot(id) { spot in
            switch field {
            case .size: spot.radius = Self.spotRadius(fromSize: value)
            case .feather: spot.feather = value
            case .opacity: spot.opacity = value
            }
        }
    }

    var spotMode: SpotEdit.Mode { selectedSpot?.mode ?? spotDefaults.mode }

    func setSpotMode(_ mode: SpotEdit.Mode) {
        spotDefaults.mode = mode
        guard let id = selectedSpotID, selectedSpot?.mode != mode else { return }
        beginEdit()
        updateSpot(id) { $0.mode = mode }
    }

    /// [ and ] keys: smaller / larger spot.
    func resizeSpot(by factor: Double) {
        let current = selectedSpot?.radius ?? spotDefaults.radius
        let next = min(max(current * factor, 0.002), 0.15)
        spotDefaults.radius = next
        if let id = selectedSpotID {
            beginEdit()
            updateSpot(id) { $0.radius = next }
        }
    }

    func updateSpot(_ id: UUID, _ change: (inout SpotEdit) -> Void) {
        guard let index = settings.spots.firstIndex(where: { $0.id == id }) else { return }
        var spot = settings.spots[index]
        change(&spot)
        guard spot != settings.spots[index] else { return }
        set(\.spots[index], spot)
    }

    func deleteSpot(_ id: UUID) {
        guard settings.spots.contains(where: { $0.id == id }) else { return }
        beginEdit()
        set(\.spots, settings.spots.filter { $0.id != id })
        if selectedSpotID == id { selectedSpotID = nil }
    }

    func clearSpots() {
        guard !settings.spots.isEmpty else { return }
        beginEdit()
        set(\.spots, [])
        selectedSpotID = nil
    }

    // MARK: - Clicks and drags on the photo

    func spotPointer(_ event: PointerEvent) {
        guard let mapper = frameMapper else { return }
        let p = MaskPoint(mapper.toSource(event.point))

        switch event.phase {
        case .began:
            let scale = mapper.viewScale(in: event.rect) * mapper.longSide
            func hit(_ center: MaskPoint, _ radius: Double) -> Bool {
                let v = mapper.toView(center, in: event.rect)
                return hypot(v.x - event.location.x, v.y - event.location.y) <= max(CGFloat(radius) * scale, 8)
            }
            // The selected spot's source circle, then spots from the top down.
            if let selected = selectedSpot, hit(selected.source, selected.radius) {
                beginEdit()
                spotDrag = .moveSource(origin: p, source: selected.source)
                return
            }
            if let spot = settings.spots.reversed().first(where: { hit($0.center, $0.radius) }) {
                selectedSpotID = spot.id
                beginEdit()
                spotDrag = .moveSpot(origin: p, center: spot.center)
                return
            }
            beginEdit()
            var spot = SpotEdit(mode: spotDefaults.mode, center: p, source: p, radius: spotDefaults.radius,
                                feather: spotDefaults.feather, opacity: spotDefaults.opacity)
            spot.source = autoSource(center: p, radius: spot.radius, mapper: mapper)
            set(\.spots, settings.spots + [spot])
            selectedSpotID = spot.id
            spotDrag = .new(center: p, resized: false)

        case .changed:
            guard let drag = spotDrag, let id = selectedSpotID else { return }
            switch drag {
            case let .new(center, _):
                let d = mapper.pixelDelta(center, p)
                let distance = hypot(d.dx, d.dy)
                guard distance > 4 else { return }
                spotDrag = .new(center: center, resized: true)
                updateSpot(id) { $0.radius = min(max(Double(distance / mapper.longSide), 0.002), 0.15) }
            case let .moveSpot(origin, center):
                updateSpot(id) { $0.center = MaskPoint(center.x + p.x - origin.x, center.y + p.y - origin.y) }
            case let .moveSource(origin, source):
                updateSpot(id) { $0.source = MaskPoint(source.x + p.x - origin.x, source.y + p.y - origin.y) }
            }

        case .ended:
            defer { spotDrag = nil }
            // A spot sized by dragging gets a source that fits its new size.
            if case let .new(center, resized) = spotDrag, resized, let id = selectedSpotID,
               let radius = selectedSpot?.radius {
                let source = autoSource(center: center, radius: radius, mapper: mapper)
                updateSpot(id) { $0.source = source }
            }
        }
    }

    /// Picks where to copy from: nearby spots (two rings of 12 directions) whose colour is
    /// closest to the area just around the blemish, staying inside the photo.
    private func autoSource(center: MaskPoint, radius: Double, mapper: FrameMapper) -> MaskPoint {
        let w = Double(mapper.sourceSize.width), h = Double(mapper.sourceSize.height)
        let long = Double(mapper.longSide)
        let rx = radius * long / w, ry = radius * long / h
        func inside(_ q: MaskPoint) -> Bool {
            q.x - rx >= 0 && q.x + rx <= 1 && q.y - ry >= 0 && q.y + ry <= 1
        }
        func point(_ distance: Double, _ angle: Double) -> MaskPoint {
            MaskPoint(center.x + cos(angle) * distance * rx, center.y + sin(angle) * distance * ry)
        }
        var candidates: [MaskPoint] = []
        for distance in [2.3, 3.3] {
            for k in 0..<12 {
                let q = point(distance, Double(k) * .pi / 6 + .pi / 4)
                if inside(q) { candidates.append(q) }
            }
        }
        let fallback = candidates.first ?? MaskPoint(
            min(max(center.x + 2.3 * rx, rx), 1 - rx), min(max(center.y, ry), 1 - ry))
        guard let image, candidates.count > 1 else { return fallback }

        // Colours from the shown photo (which is cropped, so map each point onto it).
        let pixelsPerSource = Double(image.width) / max(Double(mapper.finalPixelSize.width), 1)
        let box = Int(min(max(radius * long * pixelsPerSource * 0.6, 1), 12))
        func sample(_ q: MaskPoint) -> SIMD3<Double>? {
            let f = mapper.toFinal(q.cgPoint)
            guard f.x >= 0, f.x <= 1, f.y >= 0, f.y <= 1 else { return nil }
            return ImageSampler.average(image, at: f, radius: box)
        }
        var ring: [SIMD3<Double>] = []
        for k in 0..<8 {
            if let c = sample(point(1.6, Double(k) * .pi / 4)) { ring.append(c) }
        }
        guard !ring.isEmpty else { return fallback }
        let target = ring.reduce(SIMD3<Double>(0, 0, 0), +) / Double(ring.count)
        var best = fallback
        var bestScore = Double.infinity
        for q in candidates {
            guard let c = sample(q) else { continue }
            let d = c - target
            let distancePenalty = hypot((q.x - center.x) / rx, (q.y - center.y) / ry) * 0.004
            let score = (d * d).sum() + distancePenalty
            if score < bestScore {
                bestScore = score
                best = q
            }
        }
        return best
    }
}
