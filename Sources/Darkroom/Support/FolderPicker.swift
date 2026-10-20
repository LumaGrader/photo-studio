import AppKit

@MainActor
enum FolderPicker {
    static func chooseFolder(
        prompt: String = "Import",
        message: String = "Choose a folder of photos. Your files stay where they are."
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
}
