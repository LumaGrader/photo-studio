import SwiftUI

/// Healing tool (Q): Heal / Clone spots, like Lightroom's Spot Removal.
struct HealingPanel: View {
    @ObservedObject var session: DevelopSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(get: { session.spotMode }, set: { session.setSpotMode($0) })) {
                ForEach(SpotEdit.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            slider("Size", .size, range: 1...100, defaultValue: 34)
            slider("Feather", .feather, range: 0...100, defaultValue: 50)
            slider("Opacity", .opacity, range: 0...100, defaultValue: 100)

            HStack {
                Text(spotCountText)
                    .font(Theme.smallFont)
                    .foregroundStyle(Theme.textDim)
                Spacer()
                if let id = session.selectedSpotID {
                    Button("Delete Spot") { session.deleteSpot(id) }
                        .controlSize(.small)
                }
                Button("Clear All") { session.clearSpots() }
                    .controlSize(.small)
                    .disabled(session.settings.spots.isEmpty)
            }
            Text(session.selectedSpot == nil
                 ? "Click a blemish to remove it (drag while clicking to size the spot). LumaGrader picks a matching area to copy from."
                 : "Drag the spot or its dashed source circle to move them. Delete removes the selected spot; [ and ] change its size.")
                .font(Theme.smallFont)
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            if let message = RetouchRenderer.errorMessage {
                Text("Healing can't run: \(message)")
                    .font(Theme.smallFont)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    private var spotCountText: String {
        let count = session.settings.spots.count
        return count == 1 ? "1 spot" : "\(count) spots"
    }

    private func slider(_ title: String, _ field: SpotField, range: ClosedRange<Double>, defaultValue: Double) -> some View {
        DevelopSlider(
            title: title,
            value: Binding(
                get: { session.spotSetting(field) },
                set: { session.setSpotSetting(field, $0.rounded()) }),
            range: range,
            format: { "\(Int($0.rounded()))" },
            onReset: {
                session.beginEdit()
                session.setSpotSetting(field, defaultValue)
            },
            onEditingChanged: { editing in
                if editing, session.selectedSpotID != nil { session.beginEdit() }
            })
    }
}

/// Spot circles on the photo: every spot, the selected one with its source and an arrow,
/// and the size of a new spot under the pointer.
struct SpotDecoration: View {
    let spots: [SpotEdit]
    let selectedID: UUID?
    let mapper: FrameMapper
    let rect: CGRect
    let hover: CGPoint?
    let newRadius: Double

    var body: some View {
        Canvas { context, _ in
            let scale = mapper.viewScale(in: rect) * mapper.longSide
            func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
            var overSpot = false
            for spot in spots {
                let c = mapper.toView(spot.center, in: rect)
                let r = max(CGFloat(spot.radius) * scale, 3)
                let selected = spot.id == selectedID
                if let hover, hypot(hover.x - c.x, hover.y - c.y) <= r { overSpot = true }
                if selected {
                    let s = mapper.toView(spot.source, in: rect)
                    if let hover, hypot(hover.x - s.x, hover.y - s.y) <= r { overSpot = true }
                    context.stroke(circle(s, r), with: .color(.white.opacity(0.9)),
                                   style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    // Arrow from the source edge to the spot edge.
                    let dx = c.x - s.x, dy = c.y - s.y
                    let length = hypot(dx, dy)
                    if length > 2 * r + 6 {
                        let ux = dx / length, uy = dy / length
                        let from = CGPoint(x: s.x + ux * r, y: s.y + uy * r)
                        let to = CGPoint(x: c.x - ux * r, y: c.y - uy * r)
                        var line = Path()
                        line.move(to: from)
                        line.addLine(to: to)
                        line.move(to: to)
                        line.addLine(to: CGPoint(x: to.x - ux * 7 - uy * 4, y: to.y - uy * 7 + ux * 4))
                        line.move(to: to)
                        line.addLine(to: CGPoint(x: to.x - ux * 7 + uy * 4, y: to.y - uy * 7 - ux * 4))
                        context.stroke(line, with: .color(.white.opacity(0.9)), lineWidth: 1.2)
                    }
                }
                context.stroke(circle(c, r), with: .color(.white.opacity(selected ? 1 : 0.7)),
                               lineWidth: selected ? 2 : 1)
            }
            if let hover, !overSpot {
                let r = max(CGFloat(newRadius) * scale, 3)
                context.stroke(circle(hover, r), with: .color(.white.opacity(0.6)), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(0.8), radius: 1)
    }
}

/// Lens Blur: background blur with bokeh, from the photo's depth map or Select Subject.
struct LensBlurPanel: View {
    @ObservedObject var session: DevelopSession

    var body: some View {
        let settings = session.settings.lensBlur
        let hasDepthMap = RetouchRenderer.depthSource(url: session.photo?.url) == .depthMap
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Apply", isOn: Binding(
                get: { settings.enabled },
                set: { on in
                    session.beginEdit()
                    session.set(\.lensBlur.enabled, on)
                }))
            .toggleStyle(.checkbox)

            Group {
                slider("Blur Amount", \.amount, defaultValue: 50)
                Picker("Bokeh", selection: Binding(
                    get: { settings.bokeh },
                    set: { value in
                        session.beginEdit()
                        session.set(\.lensBlur.bokeh, value)
                    })) {
                    ForEach(LensBlurSettings.Bokeh.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                slider("Boost", \.boost, defaultValue: 25)
                slider("Edge Softness", \.edge, defaultValue: 30)
                if hasDepthMap {
                    PanelSubheading(text: "Focus (depth map)")
                    slider("Focus Distance", \.focus, defaultValue: 0)
                    slider("Focus Range", \.focusRange, defaultValue: 20)
                }
            }
            .disabled(!settings.enabled)

            Text(hasDepthMap
                 ? "Uses this photo's depth map: Focus Distance 0 = nearest, 100 = farthest."
                 : "Keeps the subject (Select Subject) sharp and blurs the rest. iPhone Portrait photos use their depth map instead.")
                .font(Theme.smallFont)
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            if let message = RetouchRenderer.errorMessage {
                Text("Lens Blur can't run: \(message)")
                    .font(Theme.smallFont)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    private func slider(_ title: String, _ path: WritableKeyPath<LensBlurSettings, Double>,
                        defaultValue: Double) -> some View {
        let keyPath = (\DevelopSettings.lensBlur).appending(path: path)
        return DevelopSlider(
            title: title,
            value: Binding(
                get: { session.settings[keyPath: keyPath] },
                set: { session.set(keyPath, $0.rounded()) }),
            range: 0...100,
            format: { "\(Int($0.rounded()))" },
            onReset: {
                session.beginEdit()
                session.set(keyPath, defaultValue)
            },
            onEditingChanged: { editing in
                if editing { session.beginEdit() }
            })
    }
}
