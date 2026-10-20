import SwiftUI

/// Lightroom-style point curve: click to add a point, drag to move,
/// drag a point off the top/bottom of the graph to remove it.
struct CurveEditor: View {
    @ObservedObject var session: DevelopSession

    enum Channel: String, CaseIterable, Identifiable {
        case rgb = "RGB", red = "Red", green = "Green", blue = "Blue"
        var id: String { rawValue }

        var keyPath: WritableKeyPath<ToneCurvePoints, [CurvePoint]> {
            switch self {
            case .rgb: return \.rgb
            case .red: return \.red
            case .green: return \.green
            case .blue: return \.blue
            }
        }

        var color: Color {
            switch self {
            case .rgb: return .white
            case .red: return Color(red: 1, green: 0.35, blue: 0.35)
            case .green: return Color(red: 0.3, green: 0.85, blue: 0.4)
            case .blue: return Color(red: 0.35, green: 0.55, blue: 1)
            }
        }
    }

    @State private var channel: Channel = .rgb
    @State private var dragIndex: Int?
    @State private var dragActive = false

    private let hitRadius: CGFloat = 10
    private let removeMargin: CGFloat = 24

    private var points: [CurvePoint] { session.settings.curve[keyPath: channel.keyPath] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Channel", selection: $channel) {
                    ForEach(Channel.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button("Reset") {
                    session.beginEdit()
                    var curve = session.settings.curve
                    curve[keyPath: channel.keyPath] = ToneCurvePoints.identity
                    session.set(\.curve, curve)
                }
                .controlSize(.small)
                .disabled(ToneCurvePoints.isIdentity(points))
            }
            GeometryReader { geometry in
                let side = min(geometry.size.width, geometry.size.height)
                Canvas { context, size in
                    drawGrid(&context, size)
                    for other in Channel.allCases where other != channel {
                        let pts = session.settings.curve[keyPath: other.keyPath]
                        if !ToneCurvePoints.isIdentity(pts) {
                            context.stroke(curvePath(pts, size), with: .color(other.color.opacity(0.25)), lineWidth: 1)
                        }
                    }
                    context.stroke(curvePath(points, size), with: .color(channel.color), lineWidth: 1.5)
                    for point in points {
                        let p = viewPoint(point, size)
                        let dot = Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
                        context.fill(dot, with: .color(.black))
                        context.stroke(dot, with: .color(channel.color), lineWidth: 1.5)
                    }
                }
                .frame(width: side, height: side)
                .background(Color.black.opacity(0.35))
                .contentShape(Rectangle())
                .gesture(dragGesture(side: side))
            }
            .aspectRatio(1, contentMode: .fit)
            Text("Click to add a point · drag a point off the graph to remove it")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Drawing

    private func viewPoint(_ point: CurvePoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: point.x / 255 * size.width, y: (1 - point.y / 255) * size.height)
    }

    private func curvePath(_ points: [CurvePoint], _ size: CGSize) -> Path {
        let spline = CurveSpline(points)
        var path = Path()
        for i in 0...64 {
            let x = Double(i) / 64 * 255
            let p = viewPoint(CurvePoint(x: x, y: spline.value(at: x)), size)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    private func drawGrid(_ context: inout GraphicsContext, _ size: CGSize) {
        var grid = Path()
        for i in 1..<4 {
            let t = CGFloat(i) / 4
            grid.move(to: CGPoint(x: t * size.width, y: 0))
            grid.addLine(to: CGPoint(x: t * size.width, y: size.height))
            grid.move(to: CGPoint(x: 0, y: t * size.height))
            grid.addLine(to: CGPoint(x: size.width, y: t * size.height))
        }
        context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 1)
        var diagonal = Path()
        diagonal.move(to: CGPoint(x: 0, y: size.height))
        diagonal.addLine(to: CGPoint(x: size.width, y: 0))
        context.stroke(diagonal, with: .color(.white.opacity(0.08)), lineWidth: 1)
    }

    // MARK: - Editing

    private func dragGesture(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let size = CGSize(width: side, height: side)
                if !dragActive {
                    dragActive = true
                    session.beginEdit()
                    dragIndex = nearestPoint(to: value.startLocation, size) ?? insertPoint(at: value.startLocation, size)
                }
                guard let index = dragIndex else { return }
                var pts = points
                let isEndpoint = index == 0 || index == pts.count - 1
                if !isEndpoint, value.location.y < -removeMargin || value.location.y > side + removeMargin {
                    pts.remove(at: index)
                    dragIndex = nil
                    store(pts)
                    return
                }
                let lowerX = index > 0 ? pts[index - 1].x + 1 : 0
                let upperX = index < pts.count - 1 ? pts[index + 1].x - 1 : 255
                let x = min(max(Double(value.location.x / side) * 255, lowerX), upperX)
                let y = min(max((1 - Double(value.location.y / side)) * 255, 0), 255)
                pts[index] = CurvePoint(x: x.rounded(), y: y.rounded())
                store(pts)
            }
            .onEnded { _ in
                dragActive = false
                dragIndex = nil
            }
    }

    private func nearestPoint(to location: CGPoint, _ size: CGSize) -> Int? {
        var best: (Int, CGFloat)?
        for (i, point) in points.enumerated() {
            let p = viewPoint(point, size)
            let distance = hypot(p.x - location.x, p.y - location.y)
            if distance <= hitRadius, distance < (best?.1 ?? .infinity) { best = (i, distance) }
        }
        return best?.0
    }

    /// Adds a point at the click (between its neighbours) and returns its index.
    private func insertPoint(at location: CGPoint, _ size: CGSize) -> Int? {
        let x = (Double(location.x / size.width) * 255).rounded()
        let y = ((1 - Double(location.y / size.height)) * 255).rounded()
        var pts = points
        guard x > (pts.first?.x ?? 0), x < (pts.last?.x ?? 255), !pts.contains(where: { $0.x == x }) else { return nil }
        let index = pts.firstIndex { $0.x > x } ?? pts.count
        pts.insert(CurvePoint(x: x, y: min(max(y, 0), 255)), at: index)
        store(pts)
        return index
    }

    private func store(_ pts: [CurvePoint]) {
        var curve = session.settings.curve
        curve[keyPath: channel.keyPath] = pts
        session.set(\.curve, curve)
    }
}
