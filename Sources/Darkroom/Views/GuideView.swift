import SwiftUI
import AppKit

/// Help ▸ LumaGrader Guide: Features (a short tutorial for each feature), Mac Security
/// (why macOS warns about LumaGrader and how to allow it) and About.
struct GuideView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case features = "Features"
        case security = "Mac Security"
        case about = "About"
        var id: String { rawValue }
    }

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State var tab: Tab

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch tab {
                case .features: FeaturesTab()
                case .security: SecurityTab()
                case .about: AboutTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 900, height: 640)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppMark(size: 26)
            HStack(spacing: 0) {
                Text("Luma").foregroundStyle(.white)
                Text("Grader").foregroundStyle(Theme.accent)
            }
            .font(.system(size: 17, weight: .bold))
            Text("GUIDE")
                .font(.system(size: 10, weight: .medium))
                .tracking(2)
                .foregroundStyle(Theme.textDim)
            Spacer()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .background(Theme.window)
    }
}

// MARK: - Features

private struct FeaturesTab: View {
    @State private var selection: String? = GuideContent.features.first?.id
    @State private var query = ""

    private var shown: [GuideFeature] { GuideContent.features.filter { $0.matches(query) } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("Search features", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                List(selection: $selection) {
                    ForEach(GuideContent.sections, id: \.self) { section in
                        let items = shown.filter { $0.section == section }
                        if !items.isEmpty {
                            Section(section) {
                                ForEach(items) { feature in
                                    Label(feature.title, systemImage: feature.icon)
                                        .tag(Optional(feature.id))
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .frame(width: 250)
            .background(Theme.window.opacity(0.6))

            Divider()

            ScrollView {
                if let feature = GuideContent.features.first(where: { $0.id == selection }) ?? shown.first {
                    FeatureDetail(feature: feature)
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("No feature matches \"\(query)\".")
                        .foregroundStyle(Theme.textDim)
                        .padding(40)
                }
            }
        }
        .onChange(of: query) { _, _ in
            if let first = shown.first, !shown.contains(where: { $0.id == selection }) {
                selection = first.id
            }
        }
    }
}

private struct FeatureDetail: View {
    let feature: GuideFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: feature.icon)
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 48, height: 48)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(feature.section.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.textDim)
                    Text(feature.title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.textBright)
                }
            }
            Text(feature.summary)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                Text("HOW TO").font(Theme.titleFont).tracking(1).foregroundStyle(Theme.textDim)
                ForEach(Array(feature.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Theme.accent))
                        Text(step)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !feature.shortcuts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SHORTCUTS").font(Theme.titleFont).tracking(1).foregroundStyle(Theme.textDim)
                    ForEach(feature.shortcuts, id: \.self) { shortcut in
                        HStack(spacing: 12) {
                            Text(shortcut.keys)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.textBright)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Theme.panelHeader, in: RoundedRectangle(cornerRadius: 5))
                            Text(shortcut.action)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.text)
                        }
                    }
                }
            }

            if let tip = feature.tip {
                Label {
                    Text(tip).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lightbulb")
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - Mac Security

private struct SecurityTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\"Apple could not verify LumaGrader Photo Studio\" is normal")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.textBright)
                        Text("The first time LumaGrader opens on a Mac, macOS stops it and asks you to confirm. This is expected and you only do it once.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                card(title: "Why it happens", icon: "questionmark.circle") {
                    Text("macOS Gatekeeper only opens apps without asking when they're signed with a paid Apple Developer ID and notarized (checked) by Apple. LumaGrader is made by an independent developer and is shared directly, not through the App Store, so it isn't notarized. macOS can't vouch for it, so it blocks it until you say it's OK.")
                    Text("It doesn't mean something is wrong with the app. Any app shared this way gets the same warning.")
                        .foregroundStyle(Theme.textDim)
                }

                card(title: "Allow LumaGrader — macOS 15 Sequoia and newer", icon: "gearshape") {
                    numbered([
                        "Open LumaGrader Photo Studio from Applications. macOS says it \"could not verify\" the app. Click Done — not Move to Trash.",
                        "Open System Settings ▸ Privacy & Security.",
                        "Scroll down to Security. Next to \"LumaGrader Photo Studio was blocked to protect your Mac\", click Open Anyway.",
                        "Enter your Mac password (or use Touch ID), then click Open Anyway once more.",
                    ])
                    Button("Open Privacy & Security") { openPrivacySettings() }
                        .padding(.top, 4)
                }

                card(title: "Allow LumaGrader — macOS 14 Sonoma", icon: "cursorarrow.click") {
                    numbered([
                        "In Applications, right-click (or Control-click) LumaGrader Photo Studio and choose Open.",
                        "Click Open in the message that appears.",
                    ])
                }

                card(title: "If macOS says LumaGrader \"is damaged\"", icon: "wrench.and.screwdriver") {
                    Text("Same check, worded differently. Open Terminal, paste this line and press Return, then open LumaGrader normally:")
                    HStack {
                        Text("xattr -dr com.apple.quarantine \"/Applications/LumaGrader Photo Studio.app\"")
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.window, in: RoundedRectangle(cornerRadius: 6))
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("xattr -dr com.apple.quarantine \"/Applications/LumaGrader Photo Studio.app\"",
                                                           forType: .string)
                        }
                    }
                }

                card(title: "What LumaGrader does on your Mac", icon: "lock") {
                    bullet("Works fully offline: no account, no cloud, nothing is uploaded. Face finding and AI Cull run on your Mac.")
                    bullet("Never changes your original photo files. Edits, ratings and labels live in its catalog.")
                    bullet("Only reads the folders you add or import, and writes where you export, import or back up to.")
                    bullet("Only download LumaGrader from the person who made it. Don't allow apps from sources you don't trust.")
                        .foregroundStyle(Theme.textDim)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func card<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textBright)
            VStack(alignment: .leading, spacing: 8) { content() }
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panelHeader.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private func numbered(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).").monospacedDigit().foregroundStyle(Theme.accent)
                    Text(step).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(Theme.accent)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Security") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                AppMark(size: 96)
                    .padding(.top, 24)
                HStack(spacing: 0) {
                    Text("Luma").foregroundStyle(.white)
                    Text("Grader").foregroundStyle(Theme.accent)
                    Text(" Photo Studio").foregroundStyle(Theme.textDim)
                }
                .font(.system(size: 30, weight: .bold))
                Text(version)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textDim)
                    .textSelection(.enabled)
                Text("An offline photo library and RAW editor for macOS: import, cull, edit, print and tether — with your photos staying on your Mac.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)

                VStack(alignment: .leading, spacing: 10) {
                    row("Built with", "Swift, SwiftUI, Core Image, Vision and SQLite — all from Apple; no third-party code")
                    row("Requires", "macOS 14 Sonoma or newer, Apple silicon or Intel")
                    row("Your data", "~/Library/Application Support/Darkroom (catalog, backups, presets)")
                    row("Help", "support@lumagrader.app")
                    row("License", "Free and open source under the GNU GPL v3. You may use, share and change it; shared changes must stay open source.")
                }
                .padding(18)
                .frame(maxWidth: 600, alignment: .leading)
                .background(Theme.panelHeader.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 10) {
                    if Support.url != nil {
                        Button {
                            Support.open()
                        } label: {
                            Label("Support on Ko-fi", systemImage: "cup.and.saucer.fill")
                        }
                    }
                    Button("Website") {
                        if let url = URL(string: "https://lumagrader.app") { NSWorkspace.shared.open(url) }
                    }
                    Button("Email Support") {
                        if let url = URL(string: "mailto:support@lumagrader.app?subject=LumaGrader%20Photo%20Studio") { NSWorkspace.shared.open(url) }
                    }
                    Button("Source Code") {
                        if let url = URL(string: "https://github.com/LumaGrader/photo-studio") { NSWorkspace.shared.open(url) }
                    }
                    Button("Show Data Folder in Finder") {
                        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        NSWorkspace.shared.open(base.appendingPathComponent("Darkroom", isDirectory: true))
                    }
                }

                Text("© \(Calendar.current.component(.year, from: Date())) LumaGrader. Free software, GNU GPL v3.")
                    .font(Theme.smallFont)
                    .foregroundStyle(Theme.textDim)
                    .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .foregroundStyle(Theme.textDim)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
    }
}
