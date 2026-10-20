import Foundation
import CoreGraphics

/// Click-on-the-photo tools in Develop.
/// Before/after layouts (Y).
enum CompareLayout: String, CaseIterable, Identifiable {
    case off = "Off"
    case sideBySide = "Side by Side"
    case split = "Split"
    var id: String { rawValue }
}

/// One entry in the History panel.
struct HistoryStep: Identifiable {
    let id = UUID()
    let label: String
    let settings: DevelopSettings
}

enum PickerTool: Equatable {
    /// White balance eyedropper (W).
    case whiteBalance
    /// Add a Point Color swatch.
    case pointColor
    /// Color Mixer targeted adjustment: drag up/down on a colour.
    case mixer
    /// Pick the colour for a mask's Color Range.
    case maskColor
    /// Pick the tone for a mask's Luminance Range.
    case maskLuminance

    /// Every picker reads the photo's colours: shown with the magnifier, without the mask overlay.
    var samplesPhoto: Bool { true }
}

/// Brush options (Masking panel), shared by all brush masks.
struct BrushSettings: Equatable {
    /// Radius, fraction of the photo's long side.
    var size = 0.04
    var feather = 0.6
    var flow = 0.8
    var erase = false
}

/// Which Color Mixer values the sliders (and the targeted tool) change.
enum MixerMode: String, CaseIterable, Identifiable {
    case hue = "Hue", saturation = "Saturation", luminance = "Luminance"
    var id: String { rawValue }

    var keyPath: WritableKeyPath<DevelopSettings, [Double]> {
        switch self {
        case .hue: return \.hslHue
        case .saturation: return \.hslSaturation
        case .luminance: return \.hslLuminance
        }
    }
}

/// Interactive editing of one photo: keeps the decoded RAW/image ready on a
/// background queue, re-renders on every slider change (newest request wins),
/// saves to the catalog shortly after you stop, and keeps undo history.
/// Public methods are called on the main thread.
final class DevelopSession: ObservableObject {
    struct AsShot {
        let temperature: Double
        let tint: Double
    }

    static let previewMaxPixel = 2560

    @Published private(set) var photo: Photo?
    @Published private(set) var settings = DevelopSettings.default
    @Published private(set) var image: CGImage?
    /// True when `image` is the full-resolution render (100% zoom).
    @Published private(set) var imageIsFullSize = false
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false
    @Published private(set) var asShot: AsShot?
    @Published private(set) var showOriginal = false
    /// Crop tool open: the preview shows the whole straightened frame.
    @Published private(set) var cropMode = false
    @Published private(set) var isZoomed = false
    /// Pixel size of the developed photo before geometry (for the crop tool).
    @Published private(set) var sourceSize: CGSize?
    /// Full-resolution pixels per pixel of the preview render (for zoom before the full render arrives).
    @Published private(set) var previewScale: CGFloat = 1
    /// Active click-on-photo tool (nil = normal zoom/pan).
    @Published var activePicker: PickerTool? {
        didSet { if oldValue != activePicker, maskingOpen { requestRender() } }
    }
    /// Masking panel open (Shift-W): the selected mask can be drawn on and is shown in red.
    @Published var maskingOpen = false {
        didSet { if oldValue != maskingOpen { requestRender() } }
    }
    @Published var selectedMaskID: UUID? {
        didSet { if oldValue != selectedMaskID, maskingOpen { requestRender() } }
    }
    @Published var selectedComponentID: UUID?
    @Published var showMaskOverlay = true {
        didSet { if oldValue != showMaskOverlay, maskingOpen { requestRender() } }
    }
    @Published var brush = BrushSettings()
    /// Before/after layout and the photo without edits (same crop) to show beside the edit.
    @Published var compareLayout: CompareLayout = .off {
        didSet { if oldValue != compareLayout { requestRender() } }
    }
    @Published private(set) var beforeImage: CGImage?
    /// Split divider, 0…1 of the view width.
    @Published var splitPosition: CGFloat = 0.5
    private var beforeKey: String? // owned by `queue`
    /// Shown instead of the edits without saving them (preset hover, preset Amount drag).
    @Published private(set) var previewSettings: DevelopSettings?
    @Published private(set) var previewLabel: String?
    /// Mask drag in progress (see DevelopSession+Masks).
    var maskDrag: MaskDragState?
    /// Healing tool open (Q): click blemishes to remove them.
    @Published var healingOpen = false
    @Published var selectedSpotID: UUID?
    /// Mode, size, feather and opacity for new spots.
    @Published var spotDefaults = SpotDefaults()
    /// Spot drag in progress (see DevelopSession+Healing).
    var spotDrag: SpotDragState?
    @Published var mixerMode: MixerMode = .hue
    @Published var selectedPointColorID: UUID?
    /// Red/blue clipping warning on the preview (J).
    @Published private(set) var showClipping = false
    /// Auto tone / white balance search running.
    @Published private(set) var isSolving = false
    /// Set by Auto Tone so a second click can undo it.
    @Published private(set) var autoToneApplied: AutoToneApplied?

    private var mixerDragStart: (values: [Double], weights: [Double], keyPath: WritableKeyPath<DevelopSettings, [Double]>)?

    /// Called (main thread) when settings should be written to the catalog.
    var onSave: ((Int64, DevelopSettings) -> Void)?

    private let queue = DispatchQueue(label: "darkroom.develop", qos: .userInteractive)
    // Owned by `queue`:
    private var source: DevelopSource?
    private var sourcePhotoID: Int64?
    private var fullSource: DevelopSource?
    private var fullSourcePhotoID: Int64?

    /// Photos decoded (and rendered) ahead of time — the next/previous photo and the one
    /// just left — so moving between photos in Develop doesn't wait for the decode.
    private struct Prepared {
        let source: DevelopSource
        let settings: DevelopSettings
        let image: CGImage?
    }
    private var prepared: [Int64: Prepared] = [:]   // owned by `queue`
    private var preparedOrder: [Int64] = []         // owned by `queue`, oldest first
    private static let preparedLimit = 4
    private let prefetchQueue = DispatchQueue(label: "darkroom.develop.prefetch", qos: .utility)
    private var prefetchGeneration = 0              // main thread
    private let cube = ToneCubeCache()

    private let lock = NSLock()
    private var latestRequest = 0 // guarded by lock
    private var requestCounter = 0

    /// History panel: every finished change, oldest first; `historyIndex` is the step shown.
    /// Undo/redo move through it. Kept per photo while the app is open.
    @Published private(set) var history: [HistoryStep] = []
    @Published private(set) var historyIndex = 0
    private var historyByPhoto: [Int64: (steps: [HistoryStep], index: Int)] = [:]
    private var pendingSave: (() -> Void)?
    private var pendingSaveWork: DispatchWorkItem?

    var isRaw: Bool { photo?.isRaw ?? false }

    // MARK: - Loading

    func load(_ newPhoto: Photo?) {
        guard newPhoto?.id != photo?.id else { return }
        flushSave()
        if let old = photo { historyByPhoto[old.id] = (history, historyIndex) }
        // Keep the photo being left ready, so going back is instant.
        if let old = photo {
            // The shown render is reusable only if it's the plain edit (no overlays, no crop tool).
            let plain = previewSettings == nil && !imageIsFullSize && !cropMode && !showClipping
                && !showOriginal && !(maskingOpen && showMaskOverlay)
            let oldImage = plain ? image : nil, oldSettings = settings
            queue.async { [weak self] in
                guard let self, self.sourcePhotoID == old.id, let source = self.source else { return }
                self.remember(Prepared(source: source, settings: oldSettings, image: oldImage), for: old.id)
            }
        }
        photo = newPhoto
        if let newPhoto {
            let saved = historyByPhoto[newPhoto.id]
            if let saved, saved.steps.indices.contains(saved.index), saved.steps[saved.index].settings == newPhoto.develop {
                history = saved.steps
                historyIndex = saved.index
            } else {
                history = [HistoryStep(label: "Opened", settings: newPhoto.develop)]
                historyIndex = 0
            }
        } else {
            history = []
            historyIndex = 0
        }
        showOriginal = false
        cropMode = false
        activePicker = nil
        maskDrag = nil
        spotDrag = nil
        selectedSpotID = nil
        previewSettings = nil
        previewLabel = nil
        selectedMaskID = newPhoto?.develop.masks.last?.id
        selectedComponentID = newPhoto?.develop.masks.last?.components.last?.id
        selectedPointColorID = newPhoto?.develop.pointColors.last?.id
        asShot = nil
        loadFailed = false
        sourceSize = nil
        previewScale = 1
        imageIsFullSize = false
        beforeImage = nil
        queue.async { [weak self] in
            self?.fullSource = nil
            self?.fullSourcePhotoID = nil
            self?.beforeKey = nil
        }

        guard let newPhoto else {
            image = nil
            isLoading = false
            return
        }
        settings = newPhoto.develop
        image = ImageLoader.shared.cachedDisplayImage(for: newPhoto, maxPixel: ThumbnailDiskCache.maxPixel)
        isLoading = true

        let request = nextRequest()
        let url = newPhoto.url
        let id = newPhoto.id
        let settings = self.settings
        queue.async { [weak self] in
            guard let self else { return }
            let ready = self.prepared.removeValue(forKey: id)
            self.preparedOrder.removeAll { $0 == id }
            let source = ready?.source ?? DevelopRenderer.makeSource(url: url, maxPixel: Self.previewMaxPixel)
            self.source = source
            self.sourcePhotoID = id
            var rendered: CGImage?
            if let ready, ready.settings == settings, let image = ready.image {
                rendered = image
            } else if let source, self.isLatest(request) {
                rendered = DevelopRenderer.cgImage(from: source, settings: settings, cube: self.cube)
            }
            let size = source.flatMap { DevelopRenderer.developedSize(of: $0) }
            var scale: CGFloat = 1
            if let source, let size, max(size.width, size.height) > 0, source.nativeLongSide > 0 {
                scale = max(1, source.nativeLongSide / max(size.width, size.height))
            }
            let shot = source?.asShot
            DispatchQueue.main.async {
                guard self.photo?.id == id else { return }
                self.isLoading = false
                self.loadFailed = source == nil
                self.sourceSize = size
                self.previewScale = scale
                if let shot { self.asShot = AsShot(temperature: shot.temperature, tint: shot.tint) }
                if let rendered {
                    self.image = rendered
                    self.imageIsFullSize = false
                }
                if self.isZoomed { self.requestRender() }
            }
        }
    }

    /// Decodes and renders these photos in the background (the neighbours of the photo
    /// open in Develop), after a short pause so the photo just opened comes first.
    func prefetch(_ photos: [Photo]) {
        prefetchGeneration += 1
        let generation = prefetchGeneration
        let current = photo?.id
        let items = photos.filter { $0.id != current }.prefix(2).map { (id: $0.id, url: $0.url, settings: $0.develop) }
        guard !items.isEmpty else { return }
        prefetchQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            for item in items {
                guard let self else { return }
                // A newer prefetch (the user moved on) replaces this one.
                let stillWanted = DispatchQueue.main.sync { self.prefetchGeneration == generation && self.photo?.id != item.id }
                guard stillWanted else { return }
                let alreadyReady = self.queue.sync { self.prepared[item.id] != nil }
                guard !alreadyReady,
                      let source = DevelopRenderer.makeSource(url: item.url, maxPixel: Self.previewMaxPixel) else { continue }
                let image = DevelopRenderer.cgImage(from: source, settings: item.settings, cube: ToneCubeCache())
                self.queue.async {
                    self.remember(Prepared(source: source, settings: item.settings, image: image), for: item.id)
                }
            }
        }
    }

    /// Owned by `queue`.
    private func remember(_ entry: Prepared, for id: Int64) {
        prepared[id] = entry
        preparedOrder.removeAll { $0 == id }
        preparedOrder.append(id)
        while preparedOrder.count > Self.preparedLimit {
            prepared.removeValue(forKey: preparedOrder.removeFirst())
        }
    }

    // MARK: - Editing

    func set<Value>(_ keyPath: WritableKeyPath<DevelopSettings, Value>, _ value: Value) {
        guard photo != nil else { return }
        settings[keyPath: keyPath] = value
        changed()
    }

    /// Call when a slider drag starts (one undo step per drag).
    func beginEdit() {
        pushUndo()
    }

    /// Replaces the settings in one undo step (presets, paste, snapshots).
    func replaceSettings(_ new: DevelopSettings, label: String? = nil) {
        guard photo != nil, new != settings else { return }
        pushUndo()
        settings = new
        recordStep(label: label)
        changed()
    }

    func resetWhiteBalance() {
        guard photo != nil else { return }
        pushUndo()
        settings.temperature = nil
        settings.tint = nil
        changed()
    }

    func resetAll() {
        guard photo != nil, !settings.isDefault else { return }
        pushUndo()
        settings = .default
        changed()
    }

    func undo() {
        recordStep()
        guard historyIndex > 0 else { return }
        goToStep(historyIndex - 1)
    }

    func redo() {
        recordStep()
        guard historyIndex < history.count - 1 else { return }
        goToStep(historyIndex + 1)
    }

    /// History panel click: show that step (later steps stay until the next edit).
    func goToStep(_ index: Int) {
        guard photo != nil, history.indices.contains(index) else { return }
        recordStep()
        historyIndex = index
        settings = history[index].settings
        changed()
    }

    func clearHistory() {
        recordStep()
        history = [HistoryStep(label: "History cleared", settings: settings)]
        historyIndex = 0
    }

    /// Adds the current settings as a history step if they differ from the step shown.
    /// Called when an edit finishes (save, next edit, undo); slider drags become one step.
    private func recordStep(label: String? = nil) {
        guard photo != nil, history.indices.contains(historyIndex),
              settings != history[historyIndex].settings else { return }
        let name = label ?? DevelopSettings.changeLabel(from: history[historyIndex].settings, to: settings)
        history.removeSubrange((historyIndex + 1)...)
        history.append(HistoryStep(label: name, settings: settings))
        if history.count > 300 { history.removeFirst(history.count - 300) }
        historyIndex = history.count - 1
    }

    func toggleBeforeAfter() {
        guard photo != nil else { return }
        showOriginal.toggle()
        requestRender()
    }

    func setCropMode(_ on: Bool) {
        guard photo != nil, cropMode != on else { return }
        if on {
            isZoomed = false
            activePicker = nil
            maskingOpen = false
            healingOpen = false
        }
        cropMode = on
        requestRender()
    }

    func setZoomed(_ on: Bool) {
        guard photo != nil, !cropMode, isZoomed != on else { return }
        isZoomed = on
        if !on {
            queue.async { [weak self] in
                self?.fullSource = nil
                self?.fullSourcePhotoID = nil
            }
        }
        requestRender()
    }

    // MARK: - Tools

    func togglePicker(_ tool: PickerTool) {
        guard photo != nil, !cropMode else { return }
        activePicker = activePicker == tool ? nil : tool
    }

    func toggleClipping() {
        guard photo != nil else { return }
        showClipping.toggle()
        requestRender()
    }

    func toggleBlackWhite() {
        guard photo != nil else { return }
        pushUndo()
        settings.blackWhite.toggle()
        changed()
    }

    /// Lightroom-style white balance presets (RAW: Kelvin/tint; others: As Shot or Auto only).
    static let rawWhiteBalancePresets: [(name: String, temperature: Double, tint: Double)] = [
        ("Daylight", 5500, 10), ("Cloudy", 6500, 10), ("Shade", 7500, 10),
        ("Tungsten", 2850, 0), ("Fluorescent", 3800, 21), ("Flash", 5500, 0),
    ]

    func applyWhiteBalancePreset(temperature: Double, tint: Double) {
        guard photo != nil, isRaw else { return }
        pushUndo()
        settings.temperature = temperature
        settings.tint = tint
        changed()
    }

    /// White balance from a click (point 0…1 from the top-left of the photo), or Auto (nil).
    func solveWhiteBalance(at point: CGPoint?) {
        guard let photo, !isSolving else { return }
        let id = photo.id
        let crop = settings.crop
        let current = (settings.temperature, settings.tint)
        isSolving = true
        queue.async { [weak self] in
            guard let self else { return }
            var result: WhiteBalanceSolver.Result?
            if let source = self.source, self.sourcePhotoID == id {
                result = WhiteBalanceSolver.solve(source: source, crop: crop, point: point, current: current)
            }
            DispatchQueue.main.async {
                self.isSolving = false
                guard self.photo?.id == id, let result else { return }
                self.pushUndo()
                self.settings.temperature = result.temperature
                self.settings.tint = result.tint
                self.changed()
            }
        }
    }

    /// The last Auto Tone: what the six tone sliders were before and what Auto set them to.
    struct AutoToneApplied: Equatable {
        let photoID: Int64
        let before: [Double]
        let after: [Double]
    }

    /// Exposure, Contrast, Highlights, Shadows, Whites, Blacks.
    private var toneValues: [Double] {
        [settings.exposure, settings.contrast, settings.highlights,
         settings.shadows, settings.whites, settings.blacks]
    }

    private func setToneValues(_ v: [Double]) {
        guard v.count == 6 else { return }
        settings.exposure = v[0]
        settings.contrast = v[1]
        settings.highlights = v[2]
        settings.shadows = v[3]
        settings.whites = v[4]
        settings.blacks = v[5]
    }

    /// Auto is on: Auto Tone was the last change to the tone sliders of this photo.
    var isAutoToneApplied: Bool {
        guard let applied = autoToneApplied, applied.photoID == photo?.id else { return false }
        return applied.after == toneValues
    }

    /// Auto tone: sets Exposure, Contrast, Highlights, Shadows, Whites and Blacks from the
    /// photo's luminance spread (like Lightroom's Auto button). Clicking Auto again while
    /// its values are untouched puts the sliders back to what they were before.
    func autoTone() {
        guard let photo, !isSolving else { return }
        let id = photo.id
        if isAutoToneApplied, let applied = autoToneApplied {
            pushUndo()
            setToneValues(applied.before)
            autoToneApplied = nil
            changed()
            return
        }
        var probe = settings
        probe.exposure = 0
        probe.contrast = 0
        probe.highlights = 0
        probe.shadows = 0
        probe.whites = 0
        probe.blacks = 0
        probe.curve = ToneCurvePoints()
        probe.crop = settings.crop
        isSolving = true
        queue.async { [weak self] in
            guard let self else { return }
            var tone: [Double]?
            if let source = self.source, self.sourcePhotoID == id,
               let image = DevelopRenderer.cgImage(from: source, settings: probe, cube: self.cube),
               let p = ImageSampler.lumaPercentiles(image, [0.005, 0.05, 0.5, 0.95, 0.995]) {
                tone = Self.autoToneValues(p)
            }
            DispatchQueue.main.async {
                self.isSolving = false
                guard self.photo?.id == id, let tone else { return }
                self.pushUndo()
                let before = self.toneValues
                self.setToneValues(tone)
                self.autoToneApplied = AutoToneApplied(photoID: id, before: before, after: self.toneValues)
                self.changed()
            }
        }
    }

    /// Percentiles (0.5%, 5%, 50%, 95%, 99.5%, sRGB-encoded) → Exposure, Contrast,
    /// Highlights, Shadows, Whites, Blacks.
    static func autoToneValues(_ p: [Double]) -> [Double] {
        func shifted(_ v: Double, _ ev: Double) -> Double { SRGB.encode(min(1, SRGB.decode(v) * pow(2, ev))) }
        let median = max(p[2], 0.01)
        var ev = log2(SRGB.decode(0.45) / SRGB.decode(median)) * 0.75
        ev = (min(max(ev, -2), 2) * 20).rounded() / 20
        let q = p.map { shifted($0, ev) }
        let spread = q[3] - q[1]
        let contrast = spread < 0.65 ? min(35, (0.65 - spread) * 90) : 0
        let highlights = q[3] > 0.82 ? -min(100, (q[3] - 0.82) * 450) : 0
        let shadows = q[1] < 0.14 ? min(100, (0.14 - q[1]) * 450) : 0
        let whites = min(max((0.97 - q[4]) * 250, -60), 60)
        let blacks = min(max((0.03 - q[0]) * 250, -60), 60)
        return [ev, contrast, highlights, shadows, whites, blacks].enumerated().map { i, v in
            i == 0 ? v : v.rounded()
        }
    }

    // MARK: Point Color + targeted Color Mixer

    /// Adds a Point Color swatch from the colour at a point of the shown image.
    func addPointColor(at point: CGPoint) {
        guard photo != nil, let image, let color = ImageSampler.average(image, at: point) else { return }
        let lch = Oklab.lch(encoded: color)
        guard lch.c > 0.01 else { return } // greys have no colour to pick
        pushUndo()
        var swatch = PointColor(lightness: lch.l, chroma: lch.c, hue: lch.h)
        if settings.pointColors.count >= PointColor.maxCount {
            settings.pointColors.removeFirst()
        }
        swatch.range = 50
        settings.pointColors.append(swatch)
        selectedPointColorID = swatch.id
        changed()
    }

    func removePointColor(_ id: UUID) {
        guard let index = settings.pointColors.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        settings.pointColors.remove(at: index)
        if selectedPointColorID == id { selectedPointColorID = settings.pointColors.last?.id }
        changed()
    }

    /// Start of a drag with the targeted Color Mixer tool.
    func beginMixerDrag(at point: CGPoint) {
        guard photo != nil, let image, let color = ImageSampler.average(image, at: point) else {
            mixerDragStart = nil
            return
        }
        let hs = SRGB.hueSaturation(color)
        guard hs.saturation > 0.03 else {
            mixerDragStart = nil
            return
        }
        var weights = SRGB.bandWeights(hue: hs.hue)
        let top = weights.max() ?? 1
        weights = weights.map { $0 / max(top, 1e-6) }
        let keyPath = settings.blackWhite ? \DevelopSettings.bwMix : mixerMode.keyPath
        pushUndo()
        mixerDragStart = (settings[keyPath: keyPath], weights, keyPath)
    }

    /// Drag up = more, down = less (points of vertical movement).
    func updateMixerDrag(verticalTranslation dy: CGFloat) {
        guard let start = mixerDragStart else { return }
        let delta = Double(-dy) * 0.5
        var values = start.values
        for i in values.indices {
            values[i] = min(100, max(-100, (start.values[i] + delta * start.weights[i]).rounded()))
        }
        settings[keyPath: start.keyPath] = values
        changed()
    }

    func endMixerDrag() {
        mixerDragStart = nil
    }

    /// Writes any pending change now (leaving Develop, switching photo).
    func flushSave() {
        recordStep()
        pendingSaveWork?.cancel()
        pendingSaveWork = nil
        if let save = pendingSave {
            pendingSave = nil
            save()
        }
    }

    // MARK: - Private

    /// Shows `settings` on the photo without saving (nil = back to the real edits).
    func setPreview(_ settings: DevelopSettings?, label: String? = nil) {
        guard photo != nil, settings != previewSettings || label != previewLabel else { return }
        previewSettings = settings
        previewLabel = settings == nil ? nil : label
        requestRender()
    }

    private func changed() {
        if showOriginal { showOriginal = false }
        previewSettings = nil
        previewLabel = nil
        requestRender()
        scheduleSave()
    }

    /// Before a new edit: the previous edit becomes its own history step.
    private func pushUndo() {
        recordStep()
    }

    private func requestRender() {
        guard let photo else { return }
        let id = photo.id
        let url = photo.url
        let request = nextRequest()
        let settings = showOriginal ? DevelopSettings.default : (previewSettings ?? self.settings)
        let zoom = isZoomed && !cropMode
        let includeCrop = !cropMode
        let clipping = showClipping
        let overlay = maskingOpen && showMaskOverlay && !(activePicker?.samplesPhoto ?? false) && !cropMode
            ? selectedMaskID : nil
        // "Before" = no edits, same crop, so both sides line up.
        let compare = compareLayout != .off && !cropMode
        var beforeSettings = DevelopSettings.default
        beforeSettings.crop = self.settings.crop
        queue.async { [weak self] in
            guard let self, self.isLatest(request), self.sourcePhotoID == id else { return }
            var source = self.source
            if zoom {
                if self.fullSourcePhotoID != id {
                    self.fullSource = DevelopRenderer.makeSource(url: url, maxPixel: nil)
                    self.fullSourcePhotoID = id
                }
                source = self.fullSource ?? self.source
                guard self.isLatest(request) else { return }
            }
            guard let source else { return }
            let rendered = DevelopRenderer.cgImage(from: source, settings: settings, cube: self.cube,
                                                   includeCrop: includeCrop, clipping: clipping,
                                                   overlayMask: overlay)
            var before: CGImage?
            if compare {
                let key = "\(id)|\(zoom)|\(beforeSettings.crop)"
                if key != self.beforeKey {
                    before = DevelopRenderer.cgImage(from: source, settings: beforeSettings, cube: self.cube)
                    self.beforeKey = before == nil ? nil : key
                }
            }
            DispatchQueue.main.async {
                guard self.photo?.id == id, let rendered else { return }
                self.image = rendered
                self.imageIsFullSize = zoom
                if let before { self.beforeImage = before }
            }
        }
    }

    func cycleCompareLayout() {
        guard photo != nil else { return }
        let all = CompareLayout.allCases
        compareLayout = all[(all.firstIndex(of: compareLayout)! + 1) % all.count]
    }

    private func scheduleSave() {
        guard let id = photo?.id else { return }
        let settings = self.settings
        pendingSave = { [weak self] in self?.onSave?(id, settings) }
        pendingSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushSave() }
        pendingSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func nextRequest() -> Int {
        requestCounter += 1
        lock.lock()
        latestRequest = requestCounter
        lock.unlock()
        return requestCounter
    }

    private func isLatest(_ request: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return latestRequest == request
    }
}
