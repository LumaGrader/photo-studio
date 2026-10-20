import SwiftUI

/// LumaGrader Photo Studio "Signature" look: Lightroom-style layout, with its own deep-slate
/// greys (a hint of the logo's navy #011326, never pure black), small light type, and one
/// accent — the logo blue #30B2F7 — for what is active, selected or in progress.
enum Theme {
    static let appName = "LumaGrader"
    static let appFullName = "LumaGrader Photo Studio"

    static let window = Color(red: 0.086, green: 0.098, blue: 0.122)      // #16191F top bar, outer frame
    static let panel = Color(red: 0.133, green: 0.149, blue: 0.180)       // #22262E side panels
    static let panelHeader = Color(red: 0.165, green: 0.184, blue: 0.220) // #2A2F38
    static let center = Color(red: 0.106, green: 0.118, blue: 0.145)      // #1B1E25 around the photo
    static let filmstrip = Color(red: 0.075, green: 0.086, blue: 0.106)   // #13161B
    static let separator = Color.black.opacity(0.5)
    static let text = Color(red: 0.80, green: 0.82, blue: 0.85)
    static let textDim = Color(red: 0.52, green: 0.56, blue: 0.62)
    static let textBright = Color(red: 0.95, green: 0.96, blue: 0.98)
    static let selection = Color(red: 0.25, green: 0.30, blue: 0.38)      // slate blue
    static let selectionActive = Color(red: 0.38, green: 0.47, blue: 0.58)
    static let control = Color(red: 0.74, green: 0.76, blue: 0.80)
    /// Raised surfaces: panel buttons, the module switcher.
    static let raised = Color(red: 0.200, green: 0.224, blue: 0.267)      // #333944
    /// The one accent (active tools, switches, progress, the logo): LumaGrader's logo blue #30B2F7.
    static let accent = Color(red: 0.188, green: 0.698, blue: 0.969)

    /// Panel titles: small caps-style, tracked out (the app's own type style).
    static let titleFont = Font.system(size: 10, weight: .semibold)
    static let bodyFont = Font.system(size: 11)
    static let smallFont = Font.system(size: 10)

    /// Colours of the Develop sections' "has changes" dots.
    enum Accent {
        static let basic = Color(red: 0.89, green: 0.64, blue: 0.23)
        static let toneCurve = Color(red: 0.31, green: 0.64, blue: 0.88)
        static let colorMixer = Color(red: 0.83, green: 0.37, blue: 0.72)
        static let pointColor = Color(red: 0.89, green: 0.42, blue: 0.54)
        static let colorGrading = Color(red: 0.23, green: 0.70, blue: 0.64)
        static let detail = Color(red: 0.56, green: 0.64, blue: 0.72)
        static let lens = Color(red: 0.61, green: 0.48, blue: 0.88)
        static let effects = Color(red: 0.88, green: 0.48, blue: 0.22)
        static let calibration = Color(red: 0.55, green: 0.76, blue: 0.32)
        static let masking = Color(red: 0.90, green: 0.33, blue: 0.29)
        static let healing = Color(red: 0.95, green: 0.75, blue: 0.35)
        static let lensBlur = Color(red: 0.40, green: 0.70, blue: 0.95)
        static let crop = Color(white: 0.80)
        static let history = Color(red: 0.62, green: 0.62, blue: 0.40)
    }

    /// Ko-fi's brand red, for the Support button only.
    static let kofiRed = Color(red: 1.0, green: 0.369, blue: 0.357) // #FF5E5B

    static let sidePanelWidth: CGFloat = 250
    static let rightPanelWidth: CGFloat = 300
    static let filmstripHeight: CGFloat = 112
}

/// A Lightroom-style panel: header with a disclosure triangle, remembers whether it is open.
/// Closed until opened (v0.8.1 reset everyone's state to that with the "panel2." keys).
struct PanelSection<Content: View, Accessory: View>: View {
    let title: String
    /// Colour of the "has changes" dot (Develop sections).
    var accent: Color?
    /// Shows a dot in the header when the section has changes.
    var edited = false
    @AppStorage private var expanded: Bool
    /// Solo mode: the panel of this group opened last (only that one stays open).
    @AppStorage private var soloOpen: String
    @AppStorage(PanelSolo.enabledKey) private var soloMode = false
    /// Told when the header of a grouped panel is clicked (Develop: closes Masking/Healing).
    @Environment(\.panelActivated) private var panelActivated
    private let key: String
    /// Panels in a group take part in Solo mode (Develop sections).
    private let group: String?
    private let accessory: Accessory
    private let content: Content

    init(_ title: String, id: String? = nil, group: String? = nil, startExpanded: Bool = false,
         accent: Color? = nil, edited: Bool = false,
         @ViewBuilder accessory: () -> Accessory,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.accent = accent
        self.edited = edited
        self.key = id ?? title
        self.group = group
        _expanded = AppStorage(wrappedValue: startExpanded, PanelSolo.expandedKey(id ?? title))
        _soloOpen = AppStorage(wrappedValue: "", PanelSolo.openKey(group ?? ""))
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(Theme.titleFont)
                    .tracking(0.8)
                    .foregroundStyle(expanded ? Theme.textBright : Theme.text)
                if edited, let accent {
                    Circle().fill(accent).frame(width: 7, height: 7).help("Has changes")
                }
                Spacer()
                accessory
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(expanded ? Theme.accent : Theme.textDim)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Theme.panelHeader)
            // Signature look: a thin accent edge on open panels.
            .overlay(alignment: .leading) {
                if expanded {
                    Rectangle().fill(Theme.accent).frame(width: 2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.15)) {
                    expanded.toggle()
                    if expanded, group != nil { soloOpen = key }
                }
                if group != nil { panelActivated?(key) }
            }
            .contextMenu {
                if group != nil {
                    Toggle("Solo Mode", isOn: $soloMode)
                }
            }
            .onChange(of: soloOpen) { _, open in
                // Another panel of the group was opened: close this one (Solo mode).
                guard soloMode, group != nil, open != key, expanded else { return }
                withAnimation(.easeOut(duration: 0.15)) { expanded = false }
            }
            .onChange(of: soloMode) { _, on in
                if on, expanded, group != nil, soloOpen.isEmpty { soloOpen = key }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    content
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
    }
}

extension PanelSection where Accessory == EmptyView {
    init(_ title: String, id: String? = nil, group: String? = nil, startExpanded: Bool = false,
         accent: Color? = nil, edited: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.init(title, id: id, group: group, startExpanded: startExpanded, accent: accent, edited: edited,
                  accessory: { EmptyView() }, content: content)
    }
}

/// Small sub-heading inside a panel ("Tone", "Presence"…).
struct PanelSubheading: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.smallFont.weight(.semibold))
            .foregroundStyle(Theme.textDim)
            .padding(.top, 2)
    }
}

/// Flat icon button used in the toolbars under the photo.
struct ToolbarIconButton: View {
    let systemImage: String
    let help: String
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .frame(width: 28, height: 22)
                .foregroundStyle(isOn ? Theme.textBright : Theme.textDim)
                .background(isOn ? Color.white.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .bottom) {
                    // Small accent bar under an active tool.
                    if isOn {
                        Capsule().fill(Theme.accent).frame(width: 12, height: 2).offset(y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Wide flat button at the bottom of a side panel (Import…, Export…, Reset).
struct PanelButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.05), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


/// Panel open/closed state and Solo mode (one Develop panel open at a time), kept in
/// UserDefaults so the command palette can open a panel too.
/// Called with a panel's id when its header is clicked (see `PanelSection`).
private struct PanelActivatedKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var panelActivated: ((String) -> Void)? {
        get { self[PanelActivatedKey.self] }
        set { self[PanelActivatedKey.self] = newValue }
    }
}

enum PanelSolo {
    static let enabledKey = "ui.soloMode"
    static let developGroup = "develop"

    static func expandedKey(_ id: String) -> String { "panel2.\(id)" }
    static func openKey(_ group: String) -> String { "panelSolo.\(group)" }

    /// Opens a panel (and, in Solo mode, closes the others of its group).
    static func open(_ id: String, group: String? = PanelSolo.developGroup) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: expandedKey(id))
        if let group { defaults.set(id, forKey: openKey(group)) }
    }
}


/// The LumaGrader mark (same as the LumaGrader app icon): a thick coloured outline, a
/// very dark navy tile, a light-blue "L" whose foot is cut diagonally, and the cut-off
/// corner piece in the accent blue (same geometry and colours as `Resources/AppIcon`).
struct AppMark: View {
    var size: CGFloat = 18

    static let light = Color(red: 0.549, green: 0.843, blue: 0.980)   // #8CD7FA
    static let fill = Color(red: 0.004, green: 0.075, blue: 0.149)    // #011326

    var body: some View {
        Canvas { context, canvasSize in
            let s = min(canvasSize.width, canvasSize.height)
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            let tile = CGRect(x: 0, y: 0, width: s, height: s)
            let corner = s * 0.225
            context.fill(Path(roundedRect: tile, cornerRadius: corner, style: .continuous), with: .color(Theme.accent))
            let inset = s * 0.075
            context.fill(Path(roundedRect: tile.insetBy(dx: inset, dy: inset), cornerRadius: corner - inset, style: .continuous),
                         with: .color(Self.fill))

            // L: stem + foot, the foot's end cut along x - y = -0.103.
            var letter = Path()
            letter.addLines([p(0.192, 0.203), p(0.369, 0.203), p(0.369, 0.654),
                             p(0.551, 0.654), p(0.703, 0.806), p(0.192, 0.806)])
            letter.closeSubpath()
            context.fill(letter, with: .color(Self.light))

            // Corner piece: parallel cut along x - y = -0.021, rounded top-right corner.
            var piece = Path()
            piece.move(to: p(0.446, 0.467))
            piece.addArc(tangent1End: p(0.799, 0.467), tangent2End: p(0.799, 0.820), radius: 0.047 * s)
            piece.addLine(to: p(0.799, 0.820))
            piece.closeSubpath()
            context.fill(piece, with: .color(Theme.accent))
        }
        .frame(width: size, height: size)
    }
}
