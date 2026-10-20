import Foundation

/// Reads develop presets made by other photo editors: `.xmp` presets, `.dng` files that
/// carry settings, older `.lrtemplate` presets, and `.zip` packs of any of these.
/// Settings Darkroom has no equivalent for (masks, healing…) are skipped and reported.
enum PresetImporter {
    struct ImportedPreset {
        var name: String
        var settings: DevelopSettings
        var groups: Set<SettingsGroup>
        /// Human-readable list of things that were skipped.
        var skipped: [String]
    }

    struct Result {
        var presets: [ImportedPreset] = []
        /// File name → reason, for files that couldn't be read.
        var failures: [(file: String, reason: String)] = []
    }

    enum ImportError: LocalizedError {
        case unreadable
        case noSettings
        case unzipFailed

        var errorDescription: String? {
            switch self {
            case .unreadable: return "couldn't read the file"
            case .noSettings: return "no develop settings found"
            case .unzipFailed: return "couldn't unpack the zip"
            }
        }
    }

    static let fileExtensions = ["xmp", "lrtemplate", "dng", "zip"]

    /// Reads every preset in the given files (zip packs are unpacked). Runs off the main thread.
    static func importFiles(_ urls: [URL]) -> Result {
        var result = Result()
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ext == "zip" {
                do {
                    let folder = try unzip(url)
                    defer { try? FileManager.default.removeItem(at: folder) }
                    let inner = presetFiles(in: folder)
                    if inner.isEmpty {
                        result.failures.append((url.lastPathComponent, "no presets inside"))
                    }
                    for file in inner { read(file, into: &result) }
                } catch {
                    result.failures.append((url.lastPathComponent, error.localizedDescription))
                }
            } else {
                read(url, into: &result)
            }
        }
        return result
    }

    private static func read(_ url: URL, into result: inout Result) {
        do {
            result.presets.append(try readPreset(url))
        } catch {
            result.failures.append((url.lastPathComponent, error.localizedDescription))
        }
    }

    static func readPreset(_ url: URL) throws -> ImportedPreset {
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }
        let fallbackName = url.deletingPathExtension().lastPathComponent
        let values: RawValues
        switch url.pathExtension.lowercased() {
        case "lrtemplate":
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            else { throw ImportError.unreadable }
            values = try LuaPreset.parse(text)
        case "dng":
            guard let xmp = extractXMP(from: data) else { throw ImportError.noSettings }
            values = XMPPreset.parse(xmp)
        default:
            values = XMPPreset.parse(data)
        }
        guard !values.scalars.isEmpty || !values.lists.isEmpty else { throw ImportError.noSettings }
        var preset = map(values)
        preset.name = values.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? fallbackName
        guard !preset.groups.isEmpty else { throw ImportError.noSettings }
        return preset
    }

    // MARK: - Files

    private static func unzip(_ url: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DarkroomPresets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", url.path, folder.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: folder)
            throw ImportError.unzipFailed
        }
        return folder
    }

    private static func presetFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if url.pathComponents.contains("__MACOSX") { continue }
            let ext = url.pathExtension.lowercased()
            if ["xmp", "lrtemplate", "dng"].contains(ext) { files.append(url) }
        }
        return files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// The XMP packet stored inside a DNG (or any file).
    static func extractXMP(from data: Data) -> Data? {
        guard let start = data.range(of: Data("<x:xmpmeta".utf8)),
              let end = data.range(of: Data("</x:xmpmeta>".utf8), in: start.upperBound..<data.endIndex)
        else { return nil }
        return data.subdata(in: start.lowerBound..<end.upperBound)
    }

    // MARK: - Mapping (setting names as used in .xmp / .lrtemplate files)

    /// Settings read from a file, before mapping.
    struct RawValues {
        var name: String?
        var scalars: [String: String] = [:]
        var lists: [String: [String]] = [:]
        var lookName: String?
        /// Top-level keys seen (to report unsupported features).
        var keys: Set<String> = []
    }

    private static let bandNames = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]

    static func map(_ v: RawValues) -> ImportedPreset {
        var s = DevelopSettings()
        var groups = Set<SettingsGroup>()
        var skipped: [String] = []

        func number(_ key: String) -> Double? {
            guard let text = v.scalars[key] else { return nil }
            return Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: ""))
        }
        func flag(_ key: String) -> Bool? {
            guard let text = v.scalars[key]?.lowercased() else { return nil }
            return text == "true" || text == "1"
        }
        func set(_ key: String, _ group: SettingsGroup, _ apply: (Double) -> Void) {
            if let value = number(key) {
                apply(value)
                groups.insert(group)
            }
        }

        // Profile
        if let look = v.lookName?.trimmingCharacters(in: .whitespaces), !look.isEmpty {
            groups.insert(.profile)
            let similar: [(String, RawProfile)] = [
                ("Standard", .standard), ("Vivid", .vivid), ("Portrait", .portrait),
                ("Landscape", .landscape), ("Neutral", .neutral),
            ]
            if look.localizedCaseInsensitiveContains("Monochrome") {
                s.blackWhite = true
                s.profile = .monochrome
                groups.insert(.colorMixer)
            } else if look == "Adobe Color" {
                s.profile = nil
            } else if let match = similar.first(where: { look.localizedCaseInsensitiveContains($0.0) }) {
                s.profile = match.1
                if !look.hasPrefix("Adobe") {
                    skipped.append("Profile “\(look)” (\(Theme.appName) \(match.0) used)")
                }
            } else {
                skipped.append("Profile “\(look)” (\(Theme.appName) Color used)")
            }
        }

        // White balance
        let whiteBalance = v.scalars["WhiteBalance"]
        if let temperature = number("Temperature"), whiteBalance != "As Shot" {
            s.temperature = temperature
            s.tint = number("Tint") ?? 0
            groups.insert(.whiteBalance)
        } else if number("IncrementalTemperature") != nil || number("IncrementalTint") != nil {
            s.temperature = number("IncrementalTemperature") ?? 0
            s.tint = number("IncrementalTint") ?? 0
            groups.insert(.whiteBalance)
        } else if whiteBalance == "As Shot" {
            groups.insert(.whiteBalance)
        } else if let whiteBalance, whiteBalance != "Custom" {
            skipped.append("White balance “\(whiteBalance)”")
        }

        // Tone
        set("Exposure2012", .tone) { s.exposure = $0 }
        set("Contrast2012", .tone) { s.contrast = $0 }
        set("Highlights2012", .tone) { s.highlights = $0 }
        set("Shadows2012", .tone) { s.shadows = $0 }
        set("Whites2012", .tone) { s.whites = $0 }
        set("Blacks2012", .tone) { s.blacks = $0 }

        // Presence
        set("Texture", .presence) { s.effects.texture = $0 }
        set("Clarity2012", .presence) { s.effects.clarity = $0 }
        set("Dehaze", .presence) { s.effects.dehaze = $0 }
        set("Vibrance", .presence) { s.vibrance = $0 }
        set("Saturation", .presence) { s.saturation = $0 }
        if let grayscale = flag("ConvertToGrayscale") {
            s.blackWhite = s.blackWhite || grayscale
            groups.insert(.colorMixer)
        }
        for (i, band) in bandNames.enumerated() {
            set("GrayMixer\(band)", .colorMixer) { s.bwMix[i] = $0 }
        }

        // Color Mixer
        for (i, band) in bandNames.enumerated() {
            set("HueAdjustment\(band)", .colorMixer) { s.hslHue[i] = $0 }
            set("SaturationAdjustment\(band)", .colorMixer) { s.hslSaturation[i] = $0 }
            set("LuminanceAdjustment\(band)", .colorMixer) { s.hslLuminance[i] = $0 }
        }

        // Color Grading (shadow/highlight hue + saturation use the split-toning names)
        set("SplitToningShadowHue", .colorGrading) { s.colorGrade.shadows.hue = $0 }
        set("SplitToningShadowSaturation", .colorGrading) { s.colorGrade.shadows.saturation = $0 }
        set("SplitToningHighlightHue", .colorGrading) { s.colorGrade.highlights.hue = $0 }
        set("SplitToningHighlightSaturation", .colorGrading) { s.colorGrade.highlights.saturation = $0 }
        set("SplitToningBalance", .colorGrading) { s.colorGrade.balance = $0 }
        set("ColorGradeShadowLum", .colorGrading) { s.colorGrade.shadows.luminance = $0 }
        set("ColorGradeHighlightLum", .colorGrading) { s.colorGrade.highlights.luminance = $0 }
        set("ColorGradeMidtoneHue", .colorGrading) { s.colorGrade.midtones.hue = $0 }
        set("ColorGradeMidtoneSat", .colorGrading) { s.colorGrade.midtones.saturation = $0 }
        set("ColorGradeMidtoneLum", .colorGrading) { s.colorGrade.midtones.luminance = $0 }
        set("ColorGradeGlobalHue", .colorGrading) { s.colorGrade.global.hue = $0 }
        set("ColorGradeGlobalSat", .colorGrading) { s.colorGrade.global.saturation = $0 }
        set("ColorGradeGlobalLum", .colorGrading) { s.colorGrade.global.luminance = $0 }
        set("ColorGradeBlending", .colorGrading) { s.colorGrade.blending = $0 }

        // Tone curve (point curves)
        let curves: [(String, WritableKeyPath<ToneCurvePoints, [CurvePoint]>)] = [
            ("ToneCurvePV2012", \.rgb), ("ToneCurvePV2012Red", \.red),
            ("ToneCurvePV2012Green", \.green), ("ToneCurvePV2012Blue", \.blue),
        ]
        for (key, path) in curves {
            guard let list = v.lists[key], let points = curvePoints(list) else { continue }
            s.curve[keyPath: path] = points
            groups.insert(.toneCurve)
        }
        set("ParametricShadows", .toneCurve) { s.curve.parametric.shadows = $0 }
        set("ParametricDarks", .toneCurve) { s.curve.parametric.darks = $0 }
        set("ParametricLights", .toneCurve) { s.curve.parametric.lights = $0 }
        set("ParametricHighlights", .toneCurve) { s.curve.parametric.highlights = $0 }
        set("ParametricShadowSplit", .toneCurve) { s.curve.parametric.shadowSplit = $0 }
        set("ParametricMidtoneSplit", .toneCurve) { s.curve.parametric.midtoneSplit = $0 }
        set("ParametricHighlightSplit", .toneCurve) { s.curve.parametric.highlightSplit = $0 }

        // Calibration
        set("RedHue", .calibration) { s.calibration.redHue = $0 }
        set("RedSaturation", .calibration) { s.calibration.redSaturation = $0 }
        set("GreenHue", .calibration) { s.calibration.greenHue = $0 }
        set("GreenSaturation", .calibration) { s.calibration.greenSaturation = $0 }
        set("BlueHue", .calibration) { s.calibration.blueHue = $0 }
        set("BlueSaturation", .calibration) { s.calibration.blueSaturation = $0 }
        if (number("ShadowTint") ?? 0) != 0 {
            skipped.append("Calibration shadows tint")
        }

        // Detail
        set("Sharpness", .detail) { s.detail.sharpening = $0 }
        set("LuminanceSmoothing", .detail) { s.detail.noiseReduction = $0 }
        set("ColorNoiseReduction", .detail) { s.detail.colorNoiseReduction = $0 }
        if let lens = flag("LensProfileEnable") {
            s.detail.lensCorrections = lens
            groups.insert(.detail)
        }

        // Effects
        set("PostCropVignetteAmount", .effects) { s.effects.vignette = $0 }
        set("PostCropVignetteMidpoint", .effects) { s.effects.vignetteMidpoint = $0 }
        set("PostCropVignetteRoundness", .effects) { s.effects.vignetteRoundness = $0 }
        set("PostCropVignetteFeather", .effects) { s.effects.vignetteFeather = $0 }
        set("PostCropVignetteHighlightContrast", .effects) { s.effects.vignetteHighlights = $0 }
        set("GrainAmount", .effects) { s.effects.grain = $0 }
        set("GrainSize", .effects) { s.effects.grainSize = $0 }
        set("GrainFrequency", .effects) { s.effects.grainRoughness = $0 }

        // Things Darkroom can't do yet
        let unsupported: [(prefixes: [String], label: String)] = [
            (["MaskGroupBasedCorrections", "PaintBasedCorrections", "GradientBasedCorrections",
              "CircularGradientBasedCorrections"], "Masks"),
            (["RetouchAreas", "RetouchInfo"], "Healing / spot removal"),
            (["PointColors"], "Point Color"),
            (["PerspectiveVertical", "PerspectiveHorizontal", "PerspectiveRotate"], "Transform"),
        ]
        for item in unsupported {
            let used = v.keys.contains { key in
                item.prefixes.contains { key.hasPrefix($0) } && (number(key).map { $0 != 0 } ?? true)
            }
            if used { skipped.append(item.label) }
        }

        return ImportedPreset(name: "", settings: s, groups: groups, skipped: skipped)
    }

    /// "x, y" pairs (XMP) or a flat list of numbers (lrtemplate) → curve points.
    private static func curvePoints(_ list: [String]) -> [CurvePoint]? {
        var numbers: [Double] = []
        for item in list {
            for part in item.split(whereSeparator: { $0 == "," || $0 == " " }) {
                if let n = Double(part) { numbers.append(n) }
            }
        }
        guard numbers.count >= 4, numbers.count % 2 == 0 else { return nil }
        var points: [CurvePoint] = []
        for i in stride(from: 0, to: numbers.count, by: 2) {
            points.append(CurvePoint(x: min(max(numbers[i], 0), 255), y: min(max(numbers[i + 1], 0), 255)))
        }
        points.sort { $0.x < $1.x }
        return points
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - XMP

/// Collects top-level `crs:` settings from an XMP packet, as attributes or as elements.
/// Settings nested inside other settings (mask and healing entries) are only noted by name.
final class XMPPreset: NSObject, XMLParserDelegate {
    private var values = PresetImporter.RawValues()
    private var stack: [String] = []
    private var text = ""
    /// Stack depth of the open top-level crs element.
    private var settingDepth: Int?
    private var list: [String] = []

    static func parse(_ data: Data) -> PresetImporter.RawValues {
        let delegate = XMPPreset()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        parser.parse()
        return delegate.values
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        stack.append(name)
        text = ""
        if let top = settingDepth {
            // <crs:Look><rdf:Description crs:Name="…">
            if stack[top - 1] == "crs:Look", stack.count == top + 1, let lookName = attributes["crs:Name"] {
                values.lookName = lookName
            }
        } else {
            if name.hasPrefix("crs:") {
                settingDepth = stack.count
                list = []
                if name == "crs:Look", let lookName = attributes["crs:Name"] {
                    values.lookName = lookName
                }
            } else {
                // rdf:Description carrying settings as attributes.
                for (key, value) in attributes where key.hasPrefix("crs:") {
                    store(String(key.dropFirst(4)), value)
                }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let depth = stack.count
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            stack.removeLast()
            text = ""
        }
        guard let top = settingDepth else { return }
        let setting = String(stack[top - 1].dropFirst(4))

        if depth == top + 2, name == "rdf:li", !trimmed.isEmpty {
            list.append(trimmed)  // crs:Setting > rdf:Seq > rdf:li
        } else if setting == "Look", depth == top + 1, name == "crs:Name", !trimmed.isEmpty {
            values.lookName = trimmed
        }
        guard depth == top else { return }
        settingDepth = nil
        if setting == "Look" { return }
        if setting == "Name" {
            if let first = list.first ?? (trimmed.isEmpty ? nil : trimmed) { values.name = first }
        } else if !list.isEmpty {
            values.lists[setting] = list
            values.keys.insert(setting)
        } else if !trimmed.isEmpty {
            store(setting, trimmed)
        } else {
            values.keys.insert(setting)  // structured (masks, healing…)
        }
        list = []
    }

    private func store(_ key: String, _ value: String) {
        if key == "Name" {
            if values.name == nil { values.name = value }
            return
        }
        values.scalars[key] = value
        values.keys.insert(key)
    }
}

// MARK: - .lrtemplate (Lua table)

private enum LuaPreset {
    indirect enum Value {
        case string(String)
        case number(Double)
        case bool(Bool)
        case table(keyed: [String: Value], list: [Value])

        var text: String? {
            switch self {
            case .string(let s): return s
            case .number(let n): return String(n)
            case .bool(let b): return b ? "true" : "false"
            case .table: return nil
            }
        }

        subscript(key: String) -> Value? {
            if case let .table(keyed, _) = self { return keyed[key] }
            return nil
        }
    }

    enum Token: Equatable {
        case name(String), string(String), number(Double), symbol(Character), end
    }

    struct ParseError: LocalizedError {
        var errorDescription: String? { "not a valid preset file" }
    }

    static func parse(_ text: String) throws -> PresetImporter.RawValues {
        var parser = Parser(tokens: try tokenize(text))
        // "s = { … }"  (sometimes "return { … }")
        var root: Value?
        while parser.peek != .end {
            if case .symbol("{") = parser.peek {
                root = try parser.value()
                break
            }
            parser.index += 1
        }
        guard let root else { throw ParseError() }
        guard let settings = root["value"]?["settings"] ?? root["settings"] else {
            throw PresetImporter.ImportError.noSettings
        }
        var values = PresetImporter.RawValues()
        values.name = (root["title"]?.text ?? root["internalName"]?.text).map(localized)
        guard case let .table(keyed, _) = settings else { throw PresetImporter.ImportError.noSettings }
        for (key, value) in keyed {
            values.keys.insert(key)
            switch value {
            case .table(let nested, let list):
                if key == "Look" {
                    values.lookName = nested["Name"]?.text
                } else if !list.isEmpty {
                    values.lists[key] = list.compactMap(\.text)
                }
            default:
                if let text = value.text { values.scalars[key] = text }
            }
        }
        return values
    }

    /// `ZSTR "$$$/Path=Name"` style strings → "Name".
    private static func localized(_ s: String) -> String {
        guard s.hasPrefix("$$$/"), let eq = s.firstIndex(of: "=") else { return s }
        return String(s[s.index(after: eq)...])
    }

    struct Parser {
        let tokens: [Token]
        var index = 0

        var peek: Token { index < tokens.count ? tokens[index] : .end }

        mutating func next() -> Token {
            defer { index += 1 }
            return peek
        }

        mutating func value() throws -> Value {
            switch next() {
            case .string(let s): return .string(s)
            case .number(let n): return .number(n)
            case .name("true"): return .bool(true)
            case .name("false"): return .bool(false)
            case .name("nil"): return .string("")
            case .name:
                // Function call with a string argument, e.g. ZSTR "…".
                if case .string(let s) = peek {
                    index += 1
                    return .string(s)
                }
                return .string("")
            case .symbol("-"):
                if case .number(let n) = next() { return .number(-n) }
                throw ParseError()
            case .symbol("{"):
                return try table()
            default:
                throw ParseError()
            }
        }

        mutating func table() throws -> Value {
            var keyed: [String: Value] = [:]
            var list: [Value] = []
            while true {
                switch peek {
                case .symbol("}"):
                    index += 1
                    return .table(keyed: keyed, list: list)
                case .symbol(","), .symbol(";"):
                    index += 1
                case .end:
                    throw ParseError()
                case .name(let key) where tokens.indices.contains(index + 1) && tokens[index + 1] == .symbol("="):
                    index += 2
                    keyed[key] = try value()
                case .symbol("["):
                    // [ "key" ] = value
                    index += 1
                    let key = try value()
                    guard next() == .symbol("]"), next() == .symbol("=") else { throw ParseError() }
                    let v = try value()
                    if let k = key.text { keyed[k] = v }
                default:
                    list.append(try value())
                }
            }
        }
    }

    static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                i += 1
            } else if c == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                // Comment (line or --[[ block ]])
                if i + 3 < chars.count, chars[i + 2] == "[", chars[i + 3] == "[" {
                    i += 4
                    while i + 1 < chars.count, !(chars[i] == "]" && chars[i + 1] == "]") { i += 1 }
                    i += 2
                } else {
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                }
            } else if c == "\"" || c == "'" {
                var s = ""
                i += 1
                while i < chars.count, chars[i] != c {
                    if chars[i] == "\\", i + 1 < chars.count {
                        i += 1
                        switch chars[i] {
                        case "n": s.append("\n")
                        case "t": s.append("\t")
                        default: s.append(chars[i])
                        }
                    } else {
                        s.append(chars[i])
                    }
                    i += 1
                }
                i += 1
                tokens.append(.string(s))
            } else if c == "[", i + 1 < chars.count, chars[i + 1] == "[" || chars[i + 1] == "=" {
                // Long string [[ … ]] or [=[ … ]=]
                var j = i + 1
                var level = 0
                while j < chars.count, chars[j] == "=" { level += 1; j += 1 }
                guard j < chars.count, chars[j] == "[" else {
                    tokens.append(.symbol("["))
                    i += 1
                    continue
                }
                j += 1
                let close = "]" + String(repeating: "=", count: level) + "]"
                var s = ""
                while j < chars.count {
                    if chars[j] == "]", String(chars[j..<min(chars.count, j + close.count)]) == close { break }
                    s.append(chars[j])
                    j += 1
                }
                tokens.append(.string(s))
                i = j + close.count
            } else if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var s = ""
                while i < chars.count, chars[i].isNumber || chars[i] == "." || chars[i] == "e" || chars[i] == "E"
                        || ((chars[i] == "-" || chars[i] == "+") && (chars[i - 1] == "e" || chars[i - 1] == "E")) {
                    s.append(chars[i])
                    i += 1
                }
                guard let n = Double(s) else { throw ParseError() }
                tokens.append(.number(n))
            } else if c.isLetter || c == "_" {
                var s = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                    s.append(chars[i])
                    i += 1
                }
                tokens.append(.name(s))
            } else {
                tokens.append(.symbol(c))
                i += 1
            }
        }
        return tokens
    }
}
