import SwiftUI
import AppKit

/// Centre of the Develop module: the photo (fit or zoomed, pannable) and the crop overlay.
struct DevelopPreview: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject var session: DevelopSession
    @ObservedObject var cropTool: CropToolState
    @State private var hover: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Theme.center
                if let image = session.image {
                    if session.cropMode {
                        let rect = Self.fitRect(CGSize(width: image.width, height: image.height), in: geometry.size)
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .shadow(color: .black.opacity(0.5), radius: 6)
                        if let frame = cropFrame {
                            CropOverlay(session: session, tool: cropTool, imageRect: rect, frame: frame)
                        }
                    } else if session.compareLayout == .sideBySide, let before = session.beforeImage {
                        HStack(spacing: 2) {
                            ZoomPanView(image: before,
                                        contentScale: session.imageIsFullSize ? 1 : session.previewScale,
                                        zoom: $store.zoom, clickZoom: store.lastZoom, resetKey: session.photo?.id)
                                .overlay(alignment: .bottom) { badge("Before").padding(10) }
                            ZoomPanView(image: image,
                                        contentScale: session.imageIsFullSize ? 1 : session.previewScale,
                                        zoom: $store.zoom, clickZoom: store.lastZoom, resetKey: session.photo?.id)
                                .overlay(alignment: .bottom) { badge("After").padding(10) }
                        }
                    } else {
                        ZoomPanView(
                            image: image,
                            contentScale: session.imageIsFullSize ? 1 : session.previewScale,
                            zoom: $store.zoom,
                            clickZoom: store.lastZoom,
                            resetKey: session.photo?.id,
                            onPick: session.activePicker == nil ? nil : { phase, point, drag in
                                handlePick(phase, point, drag)
                            },
                            onPointer: pointerHandler,
                            decoration: session.compareLayout == .split ? splitDecoration : maskDecoration,
                            onHover: { hover = $0 })
                        .contextMenu {
                            if let photo = store.selectedPhoto { PhotoContextMenu(photo: photo, store: store) }
                        }
                    }
                } else if session.loadFailed {
                    Label("Can't open this photo", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.textDim)
                }
                if session.compareLayout == .split, !session.cropMode, session.beforeImage != nil {
                    SplitHandle(position: $session.splitPosition)
                }
                if session.isLoading || session.isSolving || (session.isZoomed && !session.imageIsFullSize) {
                    ProgressView()
                        .controlSize(.small)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                if session.showOriginal { badge("Before") }
                if store.zoom.isZoomed && !session.cropMode { badge(store.zoom.label) }
                if session.cropMode { badge("Crop") }
                if session.showClipping { badge("Clipping (J)") }
                if let tool = session.activePicker { badge(Self.pickerHint(tool)) }
                if let label = session.previewLabel { badge("Preview: \(label)") }
                if session.compareLayout == .split { badge("Before | After (Y)") }
                if store.isAutoSyncing { badge("Auto Sync · \(store.selectionCount) photos") }
                if session.isHealing { badge("Healing (Q): click a spot · Delete removes · [ ] size") }
                if session.maskingOpen, let m = session.selectedMaskIndex {
                    badge(session.settings.masks[m].name)
                }
            }
            .padding(12)
        }
        .task(id: store.selectedPhotoID) {
            session.load(store.selectedPhoto)
            if let id = store.selectedPhotoID {
                session.prefetch(store.neighbors(of: id))
            }
        }
        .onAppear { session.setZoomed(store.zoom.isZoomed) }
        .onChange(of: store.zoom) { _, level in session.setZoomed(level.isZoomed) }
        .onChange(of: session.cropMode) { _, on in
            if on {
                store.zoom = .fit
            } else {
                session.setZoomed(store.zoom.isZoomed)
            }
            guard on, let size = session.sourceSize else { return }
            let frame = session.settings.crop.frameSize(for: size)
            cropTool.portrait = frame.height > frame.width
            if session.settings.crop.isDefault { cropTool.aspect = .original }
        }
        .onDisappear {
            session.flushSave()
            session.setZoomed(false)
        }
    }

    private func handlePick(_ phase: PickPhase, _ point: CGPoint, _ drag: CGSize) {
        switch session.activePicker {
        case .whiteBalance:
            guard phase == .began else { return }
            session.activePicker = nil
            session.solveWhiteBalance(at: point)
        case .pointColor:
            guard phase == .began else { return }
            session.activePicker = nil
            session.addPointColor(at: point)
        case .maskColor:
            guard phase == .began else { return }
            session.activePicker = nil
            session.pickMaskColor(at: point)
        case .maskLuminance:
            guard phase == .began else { return }
            session.activePicker = nil
            session.pickMaskLuminance(at: point)
        case .mixer:
            switch phase {
            case .began: session.beginMixerDrag(at: point)
            case .changed: session.updateMixerDrag(verticalTranslation: drag.height)
            case .ended: session.endMixerDrag()
            }
        case nil:
            break
        }
    }

    private static func pickerHint(_ tool: PickerTool) -> String {
        switch tool {
        case .whiteBalance: return "White Balance: click something grey or white (Esc to cancel)"
        case .pointColor: return "Point Color: click a colour to pick it"
        case .mixer: return "Color Mixer: drag up or down on a colour (Esc to finish)"
        case .maskColor: return "Color Range: click the colour to mask"
        case .maskLuminance: return "Luminance Range: click the tone to mask"
        }
    }

    /// Split before/after: the unedited photo drawn over the left part of the edit.
    private var splitDecoration: ((CGRect) -> AnyView)? {
        guard let before = session.beforeImage else { return nil }
        let position = session.splitPosition
        return { rect in
            AnyView(GeometryReader { geometry in
                Image(decorative: before, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: max(0, geometry.size.width * position))
                    }
            })
        }
    }

    /// Clicks and drags on the photo: mask drawing or the Healing tool.
    private var pointerHandler: ((PointerEvent) -> Void)? {
        if session.isEditingDrawnMask {
            return { event in session.maskPointer(event, optionKey: NSEvent.modifierFlags.contains(.option)) }
        }
        if session.isHealing {
            return { event in session.spotPointer(event) }
        }
        return nil
    }

    /// Magnifier for colour pickers, or guides and handles for the selected mask component.
    private var maskDecoration: ((CGRect) -> AnyView)? {
        if session.isHealing, let mapper = session.frameMapper {
            let spots = session.settings.spots
            let selected = session.selectedSpotID
            let hover = self.hover
            let radius = session.spotDefaults.radius
            return { rect in
                AnyView(SpotDecoration(spots: spots, selectedID: selected, mapper: mapper, rect: rect,
                                       hover: hover, newRadius: radius))
            }
        }
        if let tool = session.activePicker, tool.samplesPhoto, let image = session.image {
            guard let hover else { return nil }
            return { rect in AnyView(PickerLoupe(image: image, rect: rect, hover: hover)) }
        }
        guard session.isEditingDrawnMask, let component = session.selectedComponent,
              let mapper = session.frameMapper else { return nil }
        let hover = self.hover
        let brush = session.brush
        return { rect in
            AnyView(MaskDecoration(component: component, mapper: mapper, rect: rect, hover: hover,
                                   brush: brush, optionKey: NSEvent.modifierFlags.contains(.option)))
        }
    }

    private var cropFrame: CGSize? {
        session.sourceSize.map { session.settings.crop.frameSize(for: $0) }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
    }

    /// Aspect-fit rectangle with a margin.
    static func fitRect(_ image: CGSize, in container: CGSize, margin: CGFloat = 28) -> CGRect {
        let available = CGSize(width: max(1, container.width - 2 * margin), height: max(1, container.height - 2 * margin))
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(available.width / image.width, available.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

/// Right-hand Develop panels (below the histogram): tool strip, then Basic, Tone Curve,
/// Color Mixer, Color Grading — each collapsible, like Lightroom Classic.
struct DevelopPanels: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject var session: DevelopSession
    @ObservedObject var cropTool: CropToolState

    private static let minKelvin = 2000.0
    private static let maxKelvin = 50000.0

    private enum Wheel: String, CaseIterable, Identifiable {
        case shadows = "Shadows", midtones = "Midtones", highlights = "Highlights", global = "Global"
        var id: String { rawValue }

        var keyPath: WritableKeyPath<DevelopSettings, GradeWheel> {
            switch self {
            case .shadows: return \.colorGrade.shadows
            case .midtones: return \.colorGrade.midtones
            case .highlights: return \.colorGrade.highlights
            case .global: return \.colorGrade.global
            }
        }
    }

    /// Band colours for the Color Mixer labels (Red … Magenta).
    private static let bandColors: [Color] = [
        .red, .orange, .yellow, .green,
        Color(red: 0.2, green: 0.8, blue: 0.8), .blue, .purple, Color(red: 0.9, green: 0.3, blue: 0.7),
    ]

    @State private var wheel: Wheel = .shadows
    @ObservedObject private var profiles = ProfileLibrary.shared

    var body: some View {
        VStack(spacing: 0) {
            toolStrip
            if session.cropMode {
                PanelSection("Crop & Straighten", startExpanded: true, accent: Theme.Accent.crop) {
                    CropPanel(session: session, tool: cropTool, frame: session.sourceSize)
                }
            } else {
                if session.healingOpen {
                    PanelSection("Healing", startExpanded: true, accent: Theme.Accent.healing,
                                 edited: !session.settings.spots.isEmpty) { HealingPanel(session: session) }
                }
                if session.maskingOpen {
                    PanelSection("Masking", startExpanded: true, accent: Theme.Accent.masking,
                                 edited: !session.settings.masks.isEmpty) { MaskingPanel(session: session) }
                }
                PanelSection("Basic", group: PanelSolo.developGroup, accent: Theme.Accent.basic, edited: basicEdited) { basic }
                PanelSection("Tone Curve", group: PanelSolo.developGroup, accent: Theme.Accent.toneCurve, edited: !session.settings.curve.isIdentity) {
                    CurveEditor(session: session)
                    parametricCurve
                }
                PanelSection(session.settings.blackWhite ? "B&W" : "Color Mixer", id: "HSL", group: PanelSolo.developGroup, accent: Theme.Accent.colorMixer,
                             edited: session.settings.isHSLActive || session.settings.bwMix.contains { $0 != 0 }) { colorMixer }
                PanelSection("Point Color", group: PanelSolo.developGroup, accent: Theme.Accent.pointColor,
                             edited: !session.settings.activePointColors.isEmpty) { pointColor }
                PanelSection("Color Grading", group: PanelSolo.developGroup, accent: Theme.Accent.colorGrading,
                             edited: session.settings.colorGrade.isActive) { colorGrading }
                PanelSection("Detail", group: PanelSolo.developGroup, accent: Theme.Accent.detail,
                             edited: session.settings.detail.sharpening != nil || session.settings.detail.noiseReduction != 0
                                 || session.settings.detail.colorNoiseReduction != nil
                                 || session.settings.detail.denoise != 0) { detail }
                PanelSection("Lens Corrections", id: "Lens", group: PanelSolo.developGroup, accent: Theme.Accent.lens,
                             edited: session.settings.detail.lensCorrections != nil) { lens }
                PanelSection("Lens Blur", group: PanelSolo.developGroup, accent: Theme.Accent.lensBlur, edited: session.settings.lensBlur.isActive) {
                    LensBlurPanel(session: session)
                }
                PanelSection("Effects", group: PanelSolo.developGroup, accent: Theme.Accent.effects, edited: session.settings.effects.finishActive) { effects }
                PanelSection("Calibration", group: PanelSolo.developGroup, accent: Theme.Accent.calibration,
                             edited: !session.settings.calibration.isNeutral) { calibration }
            }
            if let message = DevelopKernel.errorMessage {
                Text("Basic engine in use (the Lightroom-style engine couldn't start): \(message)")
                    .font(Theme.smallFont)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .tint(Theme.control)
        .disabled(session.photo == nil)
        // Opening another section is "Done" for Masking / Healing (Lightroom does the same).
        .environment(\.panelActivated) { [session] _ in session.finishTools() }
    }

    /// Basic has changes (profile, white balance, tone or presence).
    private var basicEdited: Bool {
        let s = session.settings
        return s.profile != nil || s.lutProfile != nil || s.temperature != nil || s.tint != nil || s.blackWhite
            || [s.exposure, s.contrast, s.highlights, s.shadows, s.whites, s.blacks, s.vibrance, s.saturation,
                s.effects.texture, s.effects.clarity, s.effects.dehaze].contains { $0 != 0 }
    }

    // MARK: - Tool strip (under the histogram)

    private var toolStrip: some View {
        HStack(spacing: 4) {
            ToolbarIconButton(systemImage: "crop", help: "Crop & Straighten (R)", isOn: session.cropMode) {
                session.setCropMode(!session.cropMode)
            }
            ToolbarIconButton(systemImage: "bandage", help: "Healing: remove spots (Q)", isOn: session.healingOpen) {
                session.toggleHealing()
            }
            ToolbarIconButton(systemImage: "circle.dashed.inset.filled", help: "Masking (⇧W)", isOn: session.maskingOpen) {
                session.toggleMasking()
            }
            ToolbarIconButton(systemImage: "plus.magnifyingglass", help: "Zoom (Z)", isOn: store.zoom.isZoomed) {
                store.toggleZoom()
            }
            .disabled(session.cropMode)
            ToolbarIconButton(systemImage: session.showOriginal ? "eye.slash" : "eye",
                              help: "Before / after (\\)", isOn: session.showOriginal) {
                session.toggleBeforeAfter()
            }
            Spacer()
            Button("Reset") { session.resetAll() }
                .controlSize(.small)
                .disabled(session.settings.isDefault)
                .help("Reset all edits (⇧⌘R)")
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }

    // MARK: - Basic

    @ViewBuilder
    private var basic: some View {
        HStack {
            Text("Treatment").font(Theme.bodyFont).foregroundStyle(Theme.textDim)
            Spacer()
            Picker("Treatment", selection: Binding(
                get: { session.settings.blackWhite },
                set: { on in if on != session.settings.blackWhite { session.toggleBlackWhite() } })
            ) {
                Text("Color").tag(false)
                Text("Black & White").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Black & White (V)")
        }
        HStack {
            Text("Profile").font(Theme.bodyFont).foregroundStyle(Theme.textDim)
            Spacer()
            profilePicker
        }
        if session.settings.effectiveProfile.isLook || session.settings.lutProfile != nil {
            DevelopSlider(
                title: "Amount",
                value: Binding(
                    get: { session.settings.profileAmount },
                    set: { session.set(\.profileAmount, $0.rounded()) }),
                range: 0...200,
                format: { "\(Int($0.rounded()))" },
                onReset: {
                    session.beginEdit()
                    session.set(\.profileAmount, 100)
                },
                onEditingChanged: editingChanged)
        }
        whiteBalance
        HStack {
            PanelSubheading(text: "Tone")
            Spacer()
            Button {
                session.autoTone()
            } label: {
                Text("Auto")
                    .foregroundStyle(session.isAutoToneApplied ? Theme.accent : Theme.text)
            }
            .controlSize(.mini)
            .disabled(session.isSolving)
            .help(session.isAutoToneApplied
                  ? "Auto is on. Click again to put the tone sliders back (⌘U)"
                  : "Auto tone (⌘U)")
        }
        slider("Exposure", \.exposure, range: -5...5, format: { String(format: "%+.2f", $0) }, step: 0.01)
        slider("Contrast", \.contrast)
        slider("Highlights", \.highlights)
        slider("Shadows", \.shadows)
        slider("Whites", \.whites)
        slider("Blacks", \.blacks)
        PanelSubheading(text: "Presence")
        slider("Texture", \.effects.texture)
        slider("Clarity", \.effects.clarity)
        slider("Dehaze", \.effects.dehaze)
        slider("Vibrance", \.vibrance)
        slider("Saturation", \.saturation)
    }

    private var profileLabel: String {
        if let lut = session.settings.lutProfile { return lut }
        let profile = session.settings.effectiveProfile
        return session.isRaw || profile.isLook ? profile.shortName : "Color"
    }

    private var profilePicker: some View {
        Menu {
            Section(Theme.appName) {
                ForEach(RawProfile.allCases.filter { $0 != .cameraNeutral && (session.isRaw || !$0.isRawOnly) }) { profile in
                    Button(profile == .darkroomColor && !session.isRaw ? "Color" : profile.shortName) {
                        chooseProfile(profile, lut: nil)
                    }
                }
            }
            if session.isRaw {
                Section("Camera") {
                    Button("Camera Neutral (macOS decode)") { chooseProfile(.cameraNeutral, lut: nil) }
                }
            }
            Section("LUT Profiles") {
                ForEach(profiles.names, id: \.self) { name in
                    Button(name) { chooseProfile(session.settings.effectiveProfile.isLook ? .darkroomColor : session.settings.effectiveProfile, lut: name) }
                }
                Button("Import LUT Profile (.cube)…") {
                    if let result = profiles.chooseAndImport() {
                        if let first = result.added.first { chooseProfile(.darkroomColor, lut: first) }
                        if !result.failed.isEmpty {
                            store.notice = ("Some LUTs couldn't be imported",
                                            "Only 3D .cube LUTs are supported:\n" + result.failed.joined(separator: "\n"))
                        }
                    }
                }
                if let current = session.settings.lutProfile {
                    Button("Remove “\(current)” from \(Theme.appName)", role: .destructive) {
                        profiles.remove(current)
                        chooseProfile(session.settings.effectiveProfile, lut: nil)
                    }
                }
            }
        } label: {
            Text(profileLabel).font(Theme.bodyFont)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .fixedSize()
        .help("\(Theme.appName) Color is calibrated to look like Lightroom's Adobe Color; the other looks build on it")
    }

    private func chooseProfile(_ profile: RawProfile, lut: String?) {
        session.beginEdit()
        var next = session.settings
        next.profile = profile == .darkroomColor ? nil : profile
        next.lutProfile = lut
        if next.profile != session.settings.profile || next.lutProfile != session.settings.lutProfile {
            next.profileAmount = 100
        }
        session.replaceSettings(next)
    }

    @ViewBuilder
    private var whiteBalance: some View {
        HStack(spacing: 6) {
            Button {
                session.togglePicker(.whiteBalance)
            } label: {
                Image(systemName: "eyedropper")
                    .font(.system(size: 12))
                    .foregroundStyle(session.activePicker == .whiteBalance ? Theme.textBright : Theme.textDim)
                    .frame(width: 22, height: 20)
                    .background(session.activePicker == .whiteBalance ? Theme.selection : .clear,
                                in: RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .help("White balance selector (W): click something grey or white")
            Text("WB").font(Theme.bodyFont).foregroundStyle(Theme.textDim)
            Spacer()
            whiteBalanceMenu
        }
        if session.isRaw {
            DevelopSlider(
                title: "Temp",
                value: kelvinPosition,
                range: 0...1,
                format: { Self.kelvinLabel(Self.kelvin(atPosition: $0)) },
                parse: { text in Double(text).map { Self.position(forKelvin: $0) } },
                onReset: {
                    session.beginEdit()
                    session.set(\.temperature, nil)
                },
                onEditingChanged: editingChanged)
            DevelopSlider(
                title: "Tint",
                value: Binding(
                    get: { session.settings.tint ?? session.asShot?.tint ?? 0 },
                    set: { session.set(\.tint, $0.rounded()) }),
                range: -150...150,
                format: signed,
                onReset: {
                    session.beginEdit()
                    session.set(\.tint, nil)
                },
                onEditingChanged: editingChanged)
        } else {
            DevelopSlider(
                title: "Temp",
                value: Binding(
                    get: { session.settings.temperature ?? 0 },
                    set: { session.set(\.temperature, $0.rounded()) }),
                range: -100...100,
                format: signed,
                onReset: {
                    session.beginEdit()
                    session.set(\.temperature, nil)
                },
                onEditingChanged: editingChanged)
            DevelopSlider(
                title: "Tint",
                value: Binding(
                    get: { session.settings.tint ?? 0 },
                    set: { session.set(\.tint, $0.rounded()) }),
                range: -100...100,
                format: signed,
                onReset: {
                    session.beginEdit()
                    session.set(\.tint, nil)
                },
                onEditingChanged: editingChanged)
        }
    }

    private var whiteBalanceLabel: String {
        let s = session.settings
        guard let temperature = s.temperature else { return s.tint == nil ? "As Shot" : "Custom" }
        if session.isRaw,
           let preset = DevelopSession.rawWhiteBalancePresets.first(where: { $0.temperature == temperature && $0.tint == s.tint }) {
            return preset.name
        }
        return "Custom"
    }

    private var whiteBalanceMenu: some View {
        Menu {
            Button("As Shot") { session.resetWhiteBalance() }
            Button("Auto") { session.solveWhiteBalance(at: nil) }
            if session.isRaw {
                Divider()
                ForEach(DevelopSession.rawWhiteBalancePresets, id: \.name) { preset in
                    Button(preset.name) {
                        session.applyWhiteBalancePreset(temperature: preset.temperature, tint: preset.tint)
                    }
                }
            }
        } label: {
            Text(whiteBalanceLabel).font(Theme.bodyFont)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .fixedSize()
        .disabled(session.isSolving)
    }

    /// Shown like Lightroom: 50 K steps, 100 K above 10,000 K.
    private static func kelvinLabel(_ kelvin: Double) -> String {
        let step: Double = kelvin < 10000 ? 50 : 100
        return "\(Int((kelvin / step).rounded() * step))"
    }

    /// Kelvin slider on a log scale (2000–50000 K), like Lightroom.
    private var kelvinPosition: Binding<Double> {
        Binding(
            get: {
                let kelvin = session.settings.temperature ?? session.asShot?.temperature ?? 5500
                return Self.position(forKelvin: kelvin)
            },
            set: { position in
                let kelvin = Self.kelvin(atPosition: position)
                let step: Double = kelvin < 10000 ? 50 : 100
                session.set(\.temperature, (kelvin / step).rounded() * step)
            })
    }

    private static func kelvin(atPosition position: Double) -> Double {
        minKelvin * pow(maxKelvin / minKelvin, min(max(position, 0), 1))
    }

    private static func position(forKelvin kelvin: Double) -> Double {
        let clamped = min(max(kelvin, minKelvin), maxKelvin)
        return log(clamped / minKelvin) / log(maxKelvin / minKelvin)
    }

    // MARK: - Color Mixer (HSL)

    @ViewBuilder
    private var colorMixer: some View {
        HStack(spacing: 6) {
            Button {
                session.togglePicker(.mixer)
            } label: {
                Image(systemName: "scope")
                    .font(.system(size: 12))
                    .foregroundStyle(session.activePicker == .mixer ? Theme.textBright : Theme.textDim)
                    .frame(width: 22, height: 20)
                    .background(session.activePicker == .mixer ? Theme.selection : .clear,
                                in: RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .help("Targeted adjustment: drag up or down on a colour in the photo")
            if session.settings.blackWhite {
                Text("Black & White Mix").font(Theme.bodyFont).foregroundStyle(Theme.textDim)
                Spacer()
            } else {
                Picker("Mixer", selection: $session.mixerMode) {
                    ForEach(MixerMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }
        }
        ForEach(0..<DevelopSettings.hslBandCount, id: \.self) { band in
            slider(DevelopSettings.hslBandNames[band], mixerKeyPath(band), titleColor: Self.bandColors[band])
        }
    }

    private func mixerKeyPath(_ band: Int) -> WritableKeyPath<DevelopSettings, Double> {
        if session.settings.blackWhite { return \DevelopSettings.bwMix[band] }
        switch session.mixerMode {
        case .hue: return \DevelopSettings.hslHue[band]
        case .saturation: return \DevelopSettings.hslSaturation[band]
        case .luminance: return \DevelopSettings.hslLuminance[band]
        }
    }

    // MARK: - Point Color

    @ViewBuilder
    private var pointColor: some View {
        let points = session.settings.pointColors
        HStack(spacing: 6) {
            Button {
                session.togglePicker(.pointColor)
            } label: {
                Image(systemName: "eyedropper.halffull")
                    .font(.system(size: 12))
                    .foregroundStyle(session.activePicker == .pointColor ? Theme.textBright : Theme.textDim)
                    .frame(width: 22, height: 20)
                    .background(session.activePicker == .pointColor ? Theme.selection : .clear,
                                in: RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .help("Pick a colour from the photo (up to \(PointColor.maxCount))")
            ForEach(points) { point in
                let selected = point.id == session.selectedPointColorID
                RoundedRectangle(cornerRadius: 3)
                    .fill(Self.swatchColor(point))
                    .frame(width: 22, height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .stroke(selected ? Theme.textBright : Color.black.opacity(0.5), lineWidth: selected ? 2 : 1))
                    .onTapGesture { session.selectedPointColorID = point.id }
                    .contextMenu {
                        Button("Delete", role: .destructive) { session.removePointColor(point.id) }
                    }
            }
            Spacer()
        }
        if points.isEmpty {
            Text("Click the eyedropper, then click a colour in the photo.")
                .font(Theme.smallFont)
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        } else if let id = session.selectedPointColorID, points.contains(where: { $0.id == id }) {
            pointSlider("Hue Shift", \.hueShift, id)
            pointSlider("Sat Shift", \.saturationShift, id)
            pointSlider("Lum Shift", \.luminanceShift, id)
            pointSlider("Range", \.range, id, range: 0...100, format: { "\(Int($0.rounded()))" }, defaultValue: 50)
            HStack {
                Spacer()
                Button("Delete Swatch") { session.removePointColor(id) }
                    .controlSize(.mini)
            }
        }
    }

    /// Bound by swatch ID (an index could point past the end after a delete).
    private func pointSlider(
        _ title: String, _ path: WritableKeyPath<PointColor, Double>, _ id: UUID,
        range: ClosedRange<Double> = -100...100,
        format: @escaping (Double) -> String = { $0 == 0 ? "0" : String(format: "%+.0f", $0) },
        defaultValue: Double = 0
    ) -> some View {
        DevelopSlider(
            title: title,
            value: Binding(
                get: { session.pointColorValue(id, path) },
                set: { session.setPointColorValue(id, path, $0.rounded()) }),
            range: range,
            format: format,
            onReset: {
                session.beginEdit()
                session.setPointColorValue(id, path, defaultValue)
            },
            onEditingChanged: editingChanged)
    }

    private static func swatchColor(_ p: PointColor) -> Color {
        let h = p.hue * .pi / 180
        let linear = Oklab.toLinear(SIMD3(p.lightness, cos(h) * p.chroma, sin(h) * p.chroma))
        return Color(.sRGBLinear, red: max(0, min(1, linear.x)), green: max(0, min(1, linear.y)),
                     blue: max(0, min(1, linear.z)))
    }

    // MARK: - Parametric curve

    @ViewBuilder
    private var parametricCurve: some View {
        let number: (Double) -> String = { "\(Int($0.rounded()))" }
        PanelSubheading(text: "Region")
        slider("Highlights", \.curve.parametric.highlights)
        slider("Lights", \.curve.parametric.lights)
        slider("Darks", \.curve.parametric.darks)
        slider("Shadows", \.curve.parametric.shadows)
        DisclosureGroup("Splits") {
            slider("Shadows | Darks", \.curve.parametric.shadowSplit, range: 10...40, format: number, defaultValue: 25)
            slider("Darks | Lights", \.curve.parametric.midtoneSplit, range: 30...70, format: number, defaultValue: 50)
            slider("Lights | Highlights", \.curve.parametric.highlightSplit, range: 60...90, format: number, defaultValue: 75)
        }
        .font(Theme.bodyFont)
        .foregroundStyle(Theme.textDim)
    }

    // MARK: - Calibration

    @ViewBuilder
    private var calibration: some View {
        PanelSubheading(text: "Red Primary")
        slider("Hue", \.calibration.redHue, titleColor: .red)
        slider("Saturation", \.calibration.redSaturation, titleColor: .red)
        PanelSubheading(text: "Green Primary")
        slider("Hue", \.calibration.greenHue, titleColor: .green)
        slider("Saturation", \.calibration.greenSaturation, titleColor: .green)
        PanelSubheading(text: "Blue Primary")
        slider("Hue", \.calibration.blueHue, titleColor: .blue)
        slider("Saturation", \.calibration.blueSaturation, titleColor: .blue)
    }

    // MARK: - Color Grading

    @ViewBuilder
    private var colorGrading: some View {
        Picker("Wheel", selection: $wheel) {
            ForEach(Wheel.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        let path = wheel.keyPath
        let current = session.settings[keyPath: path]
        HStack {
            Spacer()
            ColorWheel(
                hue: current.hue,
                saturation: current.saturation,
                onBegin: { session.beginEdit() },
                onChange: { hue, saturation in
                    var updated = session.settings[keyPath: path]
                    updated.hue = hue
                    updated.saturation = saturation
                    session.set(path, updated)
                })
            .frame(width: 150, height: 150)
            Spacer()
        }
        HStack {
            Text("Hue \(Int(current.hue))°  ·  Sat \(Int(current.saturation))")
                .font(Theme.smallFont)
                .foregroundStyle(Theme.textDim)
            Spacer()
            Button("Reset") {
                session.beginEdit()
                session.set(path, GradeWheel())
            }
            .controlSize(.mini)
            .disabled(current.isNeutral && current.hue == 0)
        }
        slider("Luminance", path.appending(path: \GradeWheel.luminance))
        slider("Blending", \.colorGrade.blending, range: 0...100, format: { "\(Int($0.rounded()))" }, defaultValue: 50)
        slider("Balance", \.colorGrade.balance)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        let isRaw = session.isRaw
        PanelSubheading(text: "Sharpening")
        optionalSlider("Amount", \.detail.sharpening, range: 0...150,
                       fallback: session.settings.detail.effectiveSharpening(isRaw: isRaw))
        PanelSubheading(text: "Noise Reduction")
        slider("Luminance", \.detail.noiseReduction, range: 0...100, format: { "\(Int($0.rounded()))" })
        optionalSlider("Color", \.detail.colorNoiseReduction, range: 0...100,
                       fallback: session.settings.detail.colorNoise(isRaw: isRaw))
        PanelSubheading(text: "Denoise")
        slider("Amount", \.detail.denoise, range: 0...100, format: { "\(Int($0.rounded()))" })
        slider("Detail", \.detail.denoiseDetail, range: 0...100, format: { "\(Int($0.rounded()))" }, defaultValue: 50)
            .disabled(session.settings.detail.denoise == 0)
        Text("\(Theme.appName) Denoise: edge-aware, for high-ISO photos. Judge it at 100% (Z) — the fitted view hides noise.")
            .font(Theme.smallFont)
            .foregroundStyle(Theme.textDim)
            .fixedSize(horizontal: false, vertical: true)
        if !isRaw {
            Text("Tip: RAW files get the best sharpening and noise reduction (done during the RAW decode).")
                .font(Theme.smallFont)
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var lens: some View {
        Toggle("Enable Profile Corrections", isOn: Binding(
            get: { session.settings.detail.lensOn(isRaw: session.isRaw) },
            set: { on in
                session.beginEdit()
                session.set(\.detail.lensCorrections, on)
            }))
        .toggleStyle(.checkbox)
        .font(Theme.bodyFont)
        .disabled(!session.isRaw)
        Text(session.isRaw
             ? "Uses the lens data macOS has for this camera (distortion, vignetting). Some lenses aren't covered."
             : "Available for RAW files only.")
            .font(Theme.smallFont)
            .foregroundStyle(Theme.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Effects

    @ViewBuilder
    private var effects: some View {
        let number: (Double) -> String = { "\(Int($0.rounded()))" }
        PanelSubheading(text: "Post-Crop Vignetting")
        slider("Amount", \.effects.vignette)
        slider("Midpoint", \.effects.vignetteMidpoint, range: 0...100, format: number, defaultValue: 50)
        slider("Roundness", \.effects.vignetteRoundness)
        slider("Feather", \.effects.vignetteFeather, range: 0...100, format: number, defaultValue: 50)
        slider("Highlights", \.effects.vignetteHighlights, range: 0...100, format: number)
        PanelSubheading(text: "Grain")
        slider("Amount", \.effects.grain, range: 0...100, format: number)
        slider("Size", \.effects.grainSize, range: 0...100, format: number, defaultValue: 25)
        slider("Roughness", \.effects.grainRoughness, range: 0...100, format: number, defaultValue: 50)
    }

    // MARK: - Helpers

    /// Slider for a value whose default depends on the file type (nil = default).
    private func optionalSlider(
        _ title: String,
        _ keyPath: WritableKeyPath<DevelopSettings, Double?>,
        range: ClosedRange<Double>,
        fallback: Double
    ) -> some View {
        DevelopSlider(
            title: title,
            value: Binding(
                get: { session.settings[keyPath: keyPath] ?? fallback },
                set: { session.set(keyPath, $0.rounded()) }),
            range: range,
            format: { "\(Int($0.rounded()))" },
            onReset: {
                session.beginEdit()
                session.set(keyPath, nil)
            },
            onEditingChanged: editingChanged)
    }

    private func slider(
        _ title: String,
        _ keyPath: WritableKeyPath<DevelopSettings, Double>,
        range: ClosedRange<Double> = -100...100,
        format: @escaping (Double) -> String = { $0 == 0 ? "0" : String(format: "%+.0f", $0) },
        step: Double = 1,
        defaultValue: Double = 0,
        titleColor: Color? = nil
    ) -> some View {
        DevelopSlider(
            title: title,
            value: Binding(
                get: { session.settings[keyPath: keyPath] },
                set: { session.set(keyPath, ($0 / step).rounded() * step) }),
            range: range,
            format: format,
            titleColor: titleColor,
            onReset: {
                session.beginEdit()
                session.set(keyPath, defaultValue)
            },
            onEditingChanged: editingChanged)
    }

    private func editingChanged(_ editing: Bool) {
        if editing { session.beginEdit() }
    }

    private func signed(_ value: Double) -> String {
        value == 0 ? "0" : String(format: "%+.0f", value)
    }
}

/// Lightroom-style slider row: name on the left, value on the right, slider underneath.
/// Double-click the name or the slider to reset; click the value to type a number.
struct DevelopSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    var titleColor: Color? = nil
    /// Turns typed text into a slider value (default: the number itself).
    var parse: ((String) -> Double?)? = nil
    let onReset: () -> Void
    let onEditingChanged: (Bool) -> Void

    @State private var editingText: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 6) {
                if let titleColor {
                    Circle().fill(titleColor).frame(width: 7, height: 7)
                }
                Text(title)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 4)
                valueLabel
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onReset)
            LRSliderTrack(value: $value, range: range, onEditingChanged: onEditingChanged, onReset: onReset)
        }
        .font(Theme.bodyFont)
    }

    @ViewBuilder
    private var valueLabel: some View {
        if let text = editingText {
            TextField("", text: Binding(get: { text }, set: { editingText = $0 }))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 56)
                .focused($fieldFocused)
                .onSubmit(commitTyping)
                .onExitCommand { editingText = nil }
                .onChange(of: fieldFocused) { _, focused in
                    if !focused { commitTyping() }
                }
        } else {
            Text(format(value))
                .monospacedDigit()
                .foregroundStyle(Theme.textDim)
                .onTapGesture {
                    editingText = format(value).replacingOccurrences(of: "+", with: "")
                    fieldFocused = true
                }
        }
    }

    private func commitTyping() {
        guard let text = editingText else { return }
        editingText = nil
        let cleaned = text.replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let parsed = parse?(cleaned) ?? Double(cleaned) else { return }
        onEditingChanged(true)
        value = min(max(parsed, range.lowerBound), range.upperBound)
        onEditingChanged(false)
    }
}

/// Thin track with a small round knob; centred sliders fill from zero in the accent. Drag the knob (or click the
/// track to jump), double-click to reset.
struct LRSliderTrack: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onEditingChanged: (Bool) -> Void
    let onReset: () -> Void

    @State private var dragStart: (value: Double, onKnob: Bool)?
    @State private var lastClick = Date.distantPast
    @State private var hovering = false

    private let knobWidth: CGFloat = 9

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let x = knobX(width: width)
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color.white.opacity(0.13))
                    .frame(width: width - knobWidth, height: 3)
                    .offset(x: knobWidth / 2, y: 5.5)
                if range.lowerBound < 0 && range.upperBound > 0 {
                    // Fill from zero in the accent blue (LumaGrader's centred sliders).
                    let zero = position(of: 0, width: width)
                    Capsule()
                        .fill(Theme.accent.opacity(hovering || dragStart != nil ? 0.95 : 0.7))
                        .frame(width: abs(x - zero), height: 3)
                        .offset(x: min(x, zero), y: 5.5)
                }
                Circle()
                    .fill(hovering || dragStart != nil ? Theme.textBright : Color(white: 0.82))
                    .overlay(Circle().stroke(Theme.accent, lineWidth: dragStart != nil ? 2 : 0))
                    .shadow(color: .black.opacity(0.5), radius: 1, y: 0.5)
                    .frame(width: knobWidth, height: knobWidth)
                    .offset(x: x - knobWidth / 2, y: 2.5)
            }
            .frame(width: width, height: 14, alignment: .topLeading)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { drag in
                        if dragStart == nil {
                            let onKnob = abs(drag.startLocation.x - x) <= knobWidth
                            dragStart = (value, onKnob)
                            onEditingChanged(true)
                        }
                        guard let start = dragStart else { return }
                        let span = range.upperBound - range.lowerBound
                        let usable = max(width - knobWidth, 1)
                        // Hold ⌥ for fine control.
                        let fine = NSEvent.modifierFlags.contains(.option) ? 0.2 : 1.0
                        var next: Double
                        if start.onKnob {
                            next = start.value + Double(drag.translation.width / usable) * span * fine
                        } else {
                            next = range.lowerBound + Double((drag.location.x - knobWidth / 2) / usable) * span
                        }
                        value = min(max(next, range.lowerBound), range.upperBound)
                    }
                    .onEnded { drag in
                        dragStart = nil
                        onEditingChanged(false)
                        let moved = abs(drag.translation.width) > 2 || abs(drag.translation.height) > 2
                        guard !moved else {
                            lastClick = .distantPast
                            return
                        }
                        let now = Date()
                        if now.timeIntervalSince(lastClick) < NSEvent.doubleClickInterval {
                            lastClick = .distantPast
                            onReset()
                        } else {
                            lastClick = now
                        }
                    }
            )
        }
        .frame(height: 14)
    }

    private func position(of v: Double, width: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        let t = span > 0 ? (min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span : 0
        return knobWidth / 2 + CGFloat(t) * (width - knobWidth)
    }

    private func knobX(width: CGFloat) -> CGFloat { position(of: value, width: width) }
}

/// Upward-pointing triangle (slider knob).
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Draggable divider for the split before/after view.
struct SplitHandle: View {
    @Binding var position: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Rectangle().fill(Color.white.opacity(0.9)).frame(width: 1.5)
                Circle()
                    .fill(Color.black.opacity(0.6))
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    .overlay(Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white))
                    .frame(width: 26, height: 26)
            }
            .frame(width: 26, height: size.height)
            .contentShape(Rectangle())
            .position(x: position * size.width, y: size.height / 2)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("splitArea"))
                .onChanged { value in
                    position = min(max(value.location.x / max(size.width, 1), 0.02), 0.98)
                })
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
        }
        .coordinateSpace(name: "splitArea")
    }
}
