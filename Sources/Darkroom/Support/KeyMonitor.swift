import AppKit

/// Lightroom-style single-key shortcuts for the whole window.
/// Keys typed into a text field are left alone.
final class KeyMonitor {
    private var token: Any?

    func install(_ handler: @escaping (KeyCommand) -> Bool) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.window?.firstResponder is NSTextView { return event }
            // Leave keys alone while a sheet (e.g. Export) is open.
            if event.window?.isSheet == true || event.window?.attachedSheet != nil { return event }
            guard let command = Self.command(for: event) else { return event }
            return handler(command) ? nil : event
        }
    }

    deinit {
        if let token { NSEvent.removeMonitor(token) }
    }

    private static func command(for event: NSEvent) -> KeyCommand? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if modifiers.contains(.command) {
            // ⌘A only; every other ⌘ shortcut goes to the menus.
            let onlyCommand = !modifiers.contains(.shift) && !modifiers.contains(.option) && !modifiers.contains(.control)
            return onlyCommand && key == "a" ? .selectAll : nil
        }
        if modifiers.contains(.control) || modifiers.contains(.option) {
            return nil
        }
        switch event.keyCode {
        case 123: return .previous // ←
        case 124: return .next     // →
        case 53: return .escape
        case 36, 76: return .enter // Return, keypad Enter
        case 49: return .space
        case 48: return modifiers.contains(.shift) ? .toggleAllPanels : .togglePanels // Tab
        case 51, 117: return .delete // Delete, Forward Delete
        default: break
        }
        guard key.count == 1 else { return nil }
        if let digit = Int(key), (0...5).contains(digit) { return .rating(digit) }
        if let digit = Int(key), let label = ColorLabel.forKey(digit) { return .label(label) }
        if modifiers.contains(.shift) {
            switch key {
            case "w": return .masking
            case "m": return .newMask(.radial)
            case "f": return .focusPeaking
            case "z": return .zoomToFocus
            default: break
            }
        }
        switch key {
        case "p": return .pick
        case "x": return .reject
        case "u": return .unflag
        case "g": return .grid
        case "e": return .loupe
        case "c": return .compare
        case "n": return .survey
        case "d": return .develop
        case "\\": return .beforeAfter
        case "r": return .crop
        case "z": return .zoom
        case "f": return .fullScreen
        case "w": return .whiteBalancePicker
        case "v": return .blackWhite
        case "j": return .clipping
        case "m": return .newMask(.linear)
        case "k": return .newMask(.brush)
        case "o": return .maskOverlay
        case "y": return .compareLayout
        case "q": return .healing
        case "[": return .smaller
        case "]": return .larger
        default: return nil
        }
    }
}
