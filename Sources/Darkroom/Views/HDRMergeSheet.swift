import SwiftUI

/// Photo Merge ▸ HDR: options for merging the selected brackets.
struct HDRMergeSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var options = HDRMergeOptions()

    var body: some View {
        let photos = store.hdrPhotos
        let running = store.hdrProgress != nil
        VStack(alignment: .leading, spacing: 14) {
            Label("HDR Merge", systemImage: "square.3.layers.3d").font(.title3.weight(.semibold))
            Text("Combines \(photos.count) photos of the same scene taken at different exposures into one photo with more detail in the highlights and shadows. The originals aren't changed; the result is saved next to them as a 16-bit TIFF.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(photos.prefix(9)) { photo in
                    Text("• \(photo.displayName)").lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.callout)

            Divider()

            Toggle("Auto Align", isOn: $options.autoAlign)
                .help("Lines the photos up (for handheld brackets)")
            Toggle("Auto Settings", isOn: $options.autoSettings)
                .help("Runs Auto Tone on the merged photo")
            HStack {
                Text("Deghost Amount")
                Picker("Deghost Amount", selection: $options.deghost) {
                    ForEach(HDRMergeOptions.Deghost.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            .help("Removes ghosts of things that moved between the shots (people, leaves, water)")

            if let progress = store.hdrProgress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error = store.hdrError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { store.showHDRSheet = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(running)
                Button("Merge") { store.mergeHDR(options: options) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || !(2...9).contains(photos.count))
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(running)
    }
}
