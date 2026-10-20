import SwiftUI
import AppKit

/// Ko-fi support link: the button in the top bar and the card after an export.
enum Support {
    /// The Ko-fi page (ko-fi.com/<username>). Empty hides every Support button.
    static let kofiUsername = "lumagrader"

    static var url: URL? {
        kofiUsername.isEmpty ? nil : URL(string: "https://ko-fi.com/\(kofiUsername)")
    }

    static func open() {
        if let url { NSWorkspace.shared.open(url) }
    }

    /// The card after an export shows at most once a week.
    private static let lastPromptKey = "support.lastPrompt"
    private static let interval: TimeInterval = 7 * 24 * 60 * 60

    /// True (and remembered) when it's time to show the card again.
    static func takePrompt() -> Bool {
        guard url != nil else { return false }
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: lastPromptKey) as? Date, Date().timeIntervalSince(last) < interval {
            return false
        }
        defaults.set(Date(), forKey: lastPromptKey)
        return true
    }
}

/// "Support" pill in the top bar.
struct SupportButton: View {
    @State private var hovering = false

    var body: some View {
        if Support.url != nil {
            Button(action: Support.open) {
                HStack(spacing: 5) {
                    Image(systemName: "cup.and.saucer.fill").font(.system(size: 10))
                    Text("Support").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Theme.kofiRed.opacity(hovering ? 1 : 0.85), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("LumaGrader is free. Support it on Ko-fi (ko-fi.com/\(Support.kofiUsername))")
        }
    }
}

/// Shown over the window when an export finishes (at most once a week).
struct SupportPromptOverlay: View {
    @ObservedObject var exports: ExportQueue
    @State private var shown = false

    var body: some View {
        ZStack {
            if shown {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { shown = false }
                card
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: shown)
        .onChange(of: exports.finishedRuns) { _, _ in
            if Support.takePrompt() { shown = true }
        }
    }

    private var card: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.accent)
            Text(exports.done > 1 ? "Your photos are exported" : "Your photo is exported")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textBright)
            Text("Enjoying LumaGrader? It's free and made by one photographer. If it saves you time, you can buy me a coffee.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Support.open()
                shown = false
            } label: {
                Label("Support on Ko-fi", systemImage: "cup.and.saucer.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(Theme.kofiRed, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack {
                Button("Show in Finder") {
                    exports.showInFinder()
                    shown = false
                }
                Spacer()
                Button("Maybe later") { shown = false }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(22)
        .frame(width: 340)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
    }
}
