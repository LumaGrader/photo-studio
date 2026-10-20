import SwiftUI

/// Choose which groups of settings to copy, or to save in a preset (like Lightroom's
/// Copy Settings / New Preset dialogs).
struct SettingsGroupsSheet: View {
    let kind: SettingsSheet
    let onCancel: () -> Void
    let onConfirm: (_ name: String, _ groups: Set<SettingsGroup>) -> Void

    @State private var name = ""
    @State private var groups = SettingsGroup.defaultSelection

    private var title: String {
        switch kind {
        case .copy: return "Copy Settings"
        case .savePreset: return "Save Preset"
        case .sync: return "Synchronize Settings"
        }
    }

    private var confirmTitle: String {
        switch kind {
        case .copy: return "Copy"
        case .savePreset: return "Save"
        case .sync: return "Synchronize"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.semibold))
            if kind == .sync {
                Text("Copies the chosen settings from the active photo to the other selected photos.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if kind == .savePreset {
                TextField("Preset name", text: $name, prompt: Text("e.g. Warm Wedding"))
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(SettingsGroup.allCases) { group in
                    Toggle(group.rawValue, isOn: Binding(
                        get: { groups.contains(group) },
                        set: { on in
                            if on { groups.insert(group) } else { groups.remove(group) }
                        }))
                }
            }
            HStack {
                Button("All") { groups = Set(SettingsGroup.allCases) }
                Button("None") { groups = [] }
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) { onConfirm(name, groups) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(groups.isEmpty || (kind == .savePreset && name.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
