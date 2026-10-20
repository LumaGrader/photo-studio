import SwiftUI

// MARK: - Centre: the page

/// The page as it will print: paper, margins, the photo (soft-proofed with the paper
/// profile), border and a line about size and resolution.
struct PrintPreview: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject var model: PrintModel
    @AppStorage("print.showGuides") private var showGuides = true

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                page(in: geo.size)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            infoLine
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .background(Theme.center)
        .onAppear { model.show(store.selectedPhoto) }
        .onChange(of: store.selectedPhoto) { _, photo in model.show(photo) }
    }

    @ViewBuilder
    private func page(in area: CGSize) -> some View {
        let paper = model.paperSize
        let scale = max(0.01, min((area.width - 64) / max(paper.width, 1), (area.height - 48) / max(paper.height, 1)))
        let paperColor = model.paperWhite.map { Color(cgColor: $0) } ?? .white

        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(paperColor)
                .frame(width: paper.width * scale, height: paper.height * scale)
                .shadow(color: .black.opacity(0.5), radius: 10, y: 3)

            if let layout = model.layout {
                if showGuides {
                    guide(layout.cell, scale: scale, color: Theme.accent.opacity(0.55))
                    let printable = model.imageableArea
                    if printable.size != paper {
                        guide(printable, scale: scale, color: Color.red.opacity(0.35))
                    }
                }
                photo(layout, scale: scale)
            }

            if model.isRendering {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .offset(x: paper.width * scale - 34, y: 0)
            }
        }
        .frame(width: paper.width * scale, height: paper.height * scale)
    }

    @ViewBuilder
    private func photo(_ layout: PrintPageLayout, scale: CGFloat) -> some View {
        let rect = layout.image
        let border = CGFloat(model.settings.borderWidth) * scale
        ZStack {
            if let image = model.preview {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
            } else {
                Rectangle().fill(Color.gray.opacity(0.25))
            }
            if border > 0 {
                Rectangle()
                    .strokeBorder(model.settings.borderColor == .black ? Color.black : Color.white, lineWidth: max(border, 0.5))
            }
        }
        .frame(width: rect.width * scale, height: rect.height * scale)
        .offset(x: rect.minX * scale, y: rect.minY * scale)
    }

    private func guide(_ rect: CGRect, scale: CGFloat, color: Color) -> some View {
        Rectangle()
            .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .frame(width: rect.width * scale, height: rect.height * scale)
            .offset(x: rect.minX * scale, y: rect.minY * scale)
    }

    private var infoLine: some View {
        HStack(spacing: 14) {
            Text(model.paperDescription)
            if let layout = model.layout {
                Text(String(format: "Photo %.2f × %.2f in @ %d ppi",
                            layout.image.width / 72, layout.image.height / 72, model.settings.resolution))
                if let native = nativeResolution(layout) {
                    if native < 180 {
                        Label("Low resolution: \(native) ppi from the file", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("The file has fewer pixels than this print size needs, so it is enlarged. Print smaller for more detail.")
                    } else {
                        Text("\(native) ppi from the file")
                    }
                }
            }
            Spacer()
            let count = store.targetIDs.count
            if count > 1 {
                Text("\(count) photos selected · one per page")
            }
        }
        .font(Theme.smallFont)
        .foregroundStyle(Theme.textDim)
        .lineLimit(1)
    }

    /// Pixels of the file per printed inch.
    private func nativeResolution(_ layout: PrintPageLayout) -> Int? {
        guard let size = model.photoSize else { return nil }
        let longInches = max(layout.image.width, layout.image.height) / 72
        guard longInches > 0 else { return nil }
        // With Fill the photo is cropped, so use the side that limits it.
        let w = layout.rotated ? size.height : size.width
        let h = layout.rotated ? size.width : size.height
        let ppi = min(w / (layout.image.width / 72), h / (layout.image.height / 72))
        return Int(ppi.rounded())
    }
}

// MARK: - Right panel

struct PrintPanels: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject var model: PrintModel
    @AppStorage("print.showGuides") private var showGuides = true

    var body: some View {
        VStack(spacing: 0) {
            PanelSection("Page", startExpanded: true) { pagePanel }
            PanelSection("Layout", id: "Print Layout", startExpanded: true) { layoutPanel }
            PanelSection("Print Job", startExpanded: true) { jobPanel }
            PanelSection("Color Management", startExpanded: true) { colorPanel }
            printButton
                .padding(12)
        }
        .tint(Theme.control)
        .onAppear { if model.profiles.isEmpty { model.scanProfiles() } }
    }

    private var settings: Binding<PrintSettings> { $model.settings }

    // Page

    private var pagePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Printer", model.printerName)
            row("Paper", model.paperDescription)
            PanelButton(title: "Page Setup…") { model.pageSetup() }
                .help("Paper size and orientation (⇧⌘P)")
        }
        .id(model.paperVersion)
    }

    // Layout

    private var layoutPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: settings.fit) {
                ForEach(PrintSettings.Fit.allCases) { Text($0 == .fit ? "Fit (whole photo)" : "Fill (crop to margins)").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Toggle("Rotate to Fit", isOn: settings.rotateToFit)
                .help("Turns the photo 90° when that makes it bigger on this paper")
            Text("Margins").font(Theme.smallFont).foregroundStyle(Theme.textDim)
            inchSlider("Top", settings.marginTop)
            inchSlider("Bottom", settings.marginBottom)
            inchSlider("Left", settings.marginLeft)
            inchSlider("Right", settings.marginRight)
            HStack {
                PanelButton(title: "Equal (Left)") {
                    let m = model.settings.marginLeft
                    model.settings.marginTop = m
                    model.settings.marginBottom = m
                    model.settings.marginRight = m
                }
                .help("Use the Left margin on all sides")
                PanelButton(title: "Borderless") {
                    model.settings.marginTop = 0
                    model.settings.marginBottom = 0
                    model.settings.marginLeft = 0
                    model.settings.marginRight = 0
                }
                .help("No margins. Choose a borderless paper size in Page Setup for true edge-to-edge prints.")
            }
            DevelopSlider(title: "Border", value: settings.borderWidth, range: 0...20,
                          format: { $0 == 0 ? "None" : String(format: "%.0f pt", $0) },
                          onReset: { model.settings.borderWidth = 0 }, onEditingChanged: { _ in })
            if model.settings.borderWidth > 0 {
                Picker("Border Color", selection: settings.borderColor) {
                    ForEach(PrintSettings.BorderColor.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Toggle("Show Guides", isOn: $showGuides)
                .help("Blue: margins · Red: what the printer can reach")
        }
    }

    private func inchSlider(_ title: String, _ value: Binding<Double>) -> some View {
        DevelopSlider(title: title, value: value, range: 0...3,
                      format: { String(format: "%.2f in", $0) },
                      parse: { Double($0.replacingOccurrences(of: "in", with: "").trimmingCharacters(in: .whitespaces)) },
                      onReset: { value.wrappedValue = 0.5 }, onEditingChanged: { _ in })
    }

    // Print job

    private var jobPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Resolution", selection: settings.resolution) {
                ForEach(PrintSettings.resolutions, id: \.self) { Text("\($0) ppi").tag($0) }
            }
            .help("300 ppi for most printers; 360 or 720 for Epson, 600 for Canon")
            Picker("Sharpening", selection: settings.sharpening) {
                ForEach(PrintSettings.Sharpening.allCases) { Text($0.rawValue).tag($0) }
            }
            if model.settings.sharpening != .off {
                Picker("Media", selection: settings.media) {
                    ForEach(PrintSettings.Media.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Toggle("Print Adjustment", isOn: settings.printAdjustment)
                .help("Brighten or add contrast for the print only, if prints come out darker or flatter than the screen. Not shown in the preview's soft proof as paper; it changes the print data.")
            if model.settings.printAdjustment {
                DevelopSlider(title: "Brightness", value: settings.brightness, range: -50...50,
                              format: { String(format: "%+.0f", $0) },
                              onReset: { model.settings.brightness = 0 }, onEditingChanged: { _ in })
                DevelopSlider(title: "Contrast", value: settings.contrast, range: -50...50,
                              format: { String(format: "%+.0f", $0) },
                              onReset: { model.settings.contrast = 0 }, onEditingChanged: { _ in })
            }
        }
    }

    // Colour management

    private var colorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Profile", selection: settings.profilePath) {
                Text("Managed by Printer").tag(String?.none)
                if !model.profiles.isEmpty { Divider() }
                ForEach(model.profiles) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
                if let selected = model.selectedProfile, !model.profiles.contains(selected) {
                    Text(selected.name).tag(Optional(selected.id))
                }
            }
            .help("The ICC profile for your printer + paper")
            HStack {
                PanelButton(title: "Add Profile…") { model.importProfile() }
                    .help("Install a paper profile (.icc) downloaded from the paper or printer maker")
                PanelButton(title: model.isScanningProfiles ? "Looking…" : "Refresh") { model.scanProfiles() }
                    .disabled(model.isScanningProfiles)
            }
            if model.profiles.isEmpty, !model.isScanningProfiles {
                Text("No printer profiles found. Install your printer's driver, or add a paper profile.")
                    .font(Theme.smallFont)
                    .foregroundStyle(Theme.textDim)
            }

            if model.settings.profilePath != nil {
                Picker("Intent", selection: settings.intent) {
                    ForEach(PrintSettings.Intent.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Perceptual: keeps very saturated colours smooth. Relative: keeps in-gamut colours exact.")
                Toggle("Simulate Paper & Ink", isOn: settings.simulatePaper)
                    .help("Soft proof: the preview shows the paper's white and the ink's black")
                Label {
                    Text("In the print dialog, open your printer's settings and turn its colour management **Off** (e.g. Epson: Color Settings ▸ Off (No Color Adjustment); Canon: Color Mode ▸ None). Choose the same paper type as the profile.")
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(Theme.smallFont)
                .foregroundStyle(Theme.textDim)
            } else {
                Text("The photo is sent as sRGB and the printer driver handles colour. Choose a paper profile for the most accurate prints.")
                    .font(Theme.smallFont)
                    .foregroundStyle(Theme.textDim)
            }
            if let notice = model.notice {
                Text(notice)
                    .font(Theme.smallFont)
                    .foregroundStyle(.orange)
                    .onTapGesture { model.notice = nil }
            }
        }
    }

    private var printButton: some View {
        let count = store.targetIDs.count
        return Button {
            store.printSelected()
        } label: {
            Text(count > 1 ? "Print \(count) Photos…" : "Print…")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .help("Print (⌘P)")
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(Theme.textDim).frame(width: 52, alignment: .leading)
            Text(value).foregroundStyle(Theme.text).lineLimit(2)
        }
        .font(Theme.bodyFont)
    }
}
