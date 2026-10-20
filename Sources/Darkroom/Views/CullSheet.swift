import SwiftUI

/// AI Cull: analyse the folder with the Mac's on-device AI, then pick and reject.
struct CullSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var options = CullOptions()
    @State private var result: [String]?

    private var analysed: Int { store.folderPhotos.filter { store.analysis[$0.id] != nil }.count }
    private var total: Int { store.folderPhotos.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("AI Cull", systemImage: "sparkles").font(.title3.weight(.semibold))
            Text("Your Mac looks at each photo on-device (nothing is uploaded): sharpness, closed eyes, screenshots, an overall aesthetic score, and runs of similar shots. Then it can pick the best of each run and reject the misses. You can undo by changing the flags; your files aren't touched.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            analysisSection

            if analysed > 0 {
                Divider()
                optionsSection
            }

            if let result {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(result, id: \.self) { Text("• \($0)") }
                }
                .font(.callout)
            }

            HStack {
                Spacer()
                Button("Close") { store.showCullSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    result = store.applyCull(options)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(analysed == 0 || store.cullProgress != nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder
    private var analysisSection: some View {
        if let progress = store.cullProgress {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                HStack {
                    Text("Analysing \(progress.done) of \(progress.total)…").font(.callout)
                    Spacer()
                    Button("Stop") { store.cancelCulling() }
                }
            }
        } else {
            HStack {
                Text(analysed == 0 ? "\(total) photos in this folder." : "\(analysed) of \(total) photos analysed.")
                    .font(.callout)
                Spacer()
                if analysed < total {
                    Button(analysed == 0 ? "Analyse Folder" : "Analyse the Rest") { store.startCulling() }
                } else {
                    Button("Analyse Again") { store.startCulling(redo: true) }
                }
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Pick the best photo of each run of similar shots", isOn: $options.pickBestOfSimilar)
            HStack {
                Text("Similar shots").foregroundStyle(.secondary)
                Slider(value: $options.similarityStrictness, in: 0...1)
                Text(options.similarityStrictness < 0.34 ? "loose" : options.similarityStrictness < 0.67 ? "normal" : "strict")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
            }
            .padding(.leading, 20)
            .disabled(!options.pickBestOfSimilar && !options.rejectOthersOfSimilar)
            Toggle("Reject the other shots in each run", isOn: $options.rejectOthersOfSimilar)
            Toggle("Reject blurry photos", isOn: $options.rejectBlurry)
            Toggle("Reject photos where everyone's eyes are closed", isOn: $options.rejectEyesClosed)
            Toggle("Reject screenshots and documents", isOn: $options.rejectUtility)
            Toggle("Rate every photo with stars (1–5) from its score", isOn: $options.setStars)
            Toggle("Keep the flags and stars I already gave", isOn: $options.keepMyChoices)
            let preview = store.cullPlan(options)
            Text(preview.summary.isEmpty ? "With these options nothing would change." : "Will do: " + preview.summary.joined(separator: "; ") + ".")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .onChange(of: options.similarityStrictness) { _, _ in result = nil }
    }
}
