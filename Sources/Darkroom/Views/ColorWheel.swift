import SwiftUI

/// Hue (angle, 0° = red at the right, counter-clockwise) and Saturation (distance from
/// the centre, 0…100) picker, like Lightroom's Color Grading wheels.
struct ColorWheel: View {
    let hue: Double
    let saturation: Double
    let onBegin: () -> Void
    let onChange: (_ hue: Double, _ saturation: Double) -> Void

    @State private var dragging = false

    /// Gradient stops for a clockwise sweep that shows hues counter-clockwise.
    private static let hueStops: [Color] = stride(from: 360, through: 0, by: -30).map {
        Color(hue: Double($0 % 360) / 360, saturation: 0.85, brightness: 0.95)
    }

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)
            let radius = diameter / 2
            let angle = hue * .pi / 180
            let distance = CGFloat(min(max(saturation, 0), 100) / 100) * radius
            ZStack {
                Circle().fill(AngularGradient(gradient: Gradient(colors: Self.hueStops), center: .center))
                Circle().fill(RadialGradient(colors: [Color(white: 0.55), Color(white: 0.55).opacity(0)],
                                             center: .center, startRadius: 0, endRadius: radius))
                Circle().stroke(Color.black.opacity(0.4), lineWidth: 1)
                Circle()
                    .stroke(Color.white, lineWidth: 2)
                    .background(Circle().fill(Color.black.opacity(0.25)))
                    .frame(width: 14, height: 14)
                    .position(x: radius + CGFloat(cos(angle)) * distance,
                              y: radius - CGFloat(sin(angle)) * distance)
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            onBegin()
                        }
                        let dx = Double(value.location.x - radius)
                        let dy = Double(radius - value.location.y)
                        var h = atan2(dy, dx) * 180 / .pi
                        if h < 0 { h += 360 }
                        let s = min(1, hypot(dx, dy) / Double(radius)) * 100
                        onChange(h.rounded(), s.rounded())
                    }
                    .onEnded { _ in dragging = false })
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
