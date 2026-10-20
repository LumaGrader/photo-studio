import AppKit
import UniformTypeIdentifiers

/// State of the Print module: settings, paper (NSPrintInfo), paper profiles and the
/// soft-proofed page preview. Mutated on the main thread only.
final class PrintModel: ObservableObject {
    @Published var settings = PrintSettings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            schedulePreview()
        }
    }
    @Published private(set) var profiles: [PrinterProfile] = []
    @Published private(set) var isScanningProfiles = false
    /// Soft-proofed photo for the page preview (Display P3).
    @Published private(set) var preview: CGImage?
    @Published private(set) var layout: PrintPageLayout?
    /// Developed size of the shown photo, in pixels.
    @Published private(set) var photoSize: CGSize?
    @Published private(set) var isRendering = false
    /// Paper colour on screen with Simulate Paper & Ink (nil = plain white).
    @Published private(set) var paperWhite: CGColor?
    /// Bumped when the paper changes (Page Setup, print dialog).
    @Published private(set) var paperVersion = 0

    private(set) var printInfo: NSPrintInfo
    private var photo: Photo?
    private var generation = 0
    private var sizeCache: [Int64: (develop: DevelopSettings, size: CGSize)] = [:]
    private let queue = DispatchQueue(label: "darklab.print.preview", qos: .userInitiated)

    private enum Keys {
        static let printer = "print.printer"
        static let paperName = "print.paperName"
        static let paperWidth = "print.paperWidth"
        static let paperHeight = "print.paperHeight"
        static let orientation = "print.orientation"
    }

    init() {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        let defaults = UserDefaults.standard
        if let name = defaults.string(forKey: Keys.printer), let printer = NSPrinter(name: name) {
            info.printer = printer
        }
        if let paper = defaults.string(forKey: Keys.paperName) {
            info.paperName = NSPrinter.PaperName(paper)
        }
        let width = defaults.double(forKey: Keys.paperWidth), height = defaults.double(forKey: Keys.paperHeight)
        if width > 0, height > 0 {
            info.paperSize = NSSize(width: width, height: height)
        }
        if defaults.object(forKey: Keys.orientation) != nil,
           let orientation = NSPrintInfo.PaperOrientation(rawValue: defaults.integer(forKey: Keys.orientation)) {
            info.orientation = orientation
        }
        Self.prepare(info)
        printInfo = info
    }

    /// The layout is ours: no margins or centring from the print system.
    private static func prepare(_ info: NSPrintInfo) {
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
    }

    private func rememberPrintInfo() {
        let defaults = UserDefaults.standard
        defaults.set(printInfo.printer.name, forKey: Keys.printer)
        defaults.set(printInfo.paperName?.rawValue, forKey: Keys.paperName)
        defaults.set(Double(printInfo.paperSize.width), forKey: Keys.paperWidth)
        defaults.set(Double(printInfo.paperSize.height), forKey: Keys.paperHeight)
        defaults.set(printInfo.orientation.rawValue, forKey: Keys.orientation)
        paperVersion += 1
    }

    // MARK: - Paper

    var paperSize: CGSize { printInfo.paperSize }

    /// Printable area from the page's top-left (the print system gives it from the bottom-left).
    var imageableArea: CGRect { Self.topLeft(printInfo) }

    static func topLeft(_ info: NSPrintInfo) -> CGRect {
        let bounds = info.imageablePageBounds
        return CGRect(x: bounds.minX, y: info.paperSize.height - bounds.maxY,
                      width: bounds.width, height: bounds.height)
    }

    var paperDescription: String {
        let size = paperSize
        let name = printInfo.localizedPaperName ?? "Custom"
        return String(format: "%@ · %.1f × %.1f in (%.0f × %.0f mm)", name,
                      size.width / 72, size.height / 72, size.width / 72 * 25.4, size.height / 72 * 25.4)
    }

    var printerName: String { printInfo.printer.name }

    @MainActor
    func pageSetup() {
        let layout = NSPageLayout()
        guard layout.runModal(with: printInfo) == NSApplication.ModalResponse.OK.rawValue else { return }
        Self.prepare(printInfo)
        rememberPrintInfo()
        schedulePreview()
    }

    // MARK: - Profiles

    var selectedProfile: PrinterProfile? {
        guard let path = settings.profilePath else { return nil }
        return profiles.first { $0.id == path }
            ?? PrintProfiles.read(URL(fileURLWithPath: path))
    }

    func scanProfiles() {
        guard !isScanningProfiles else { return }
        isScanningProfiles = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = PrintProfiles.scan()
            DispatchQueue.main.async {
                self?.profiles = found
                self?.isScanningProfiles = false
            }
        }
    }

    @MainActor
    func importProfile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "icc"), UTType(filenameExtension: "icm")].compactMap { $0 }
        panel.prompt = "Add Profile"
        panel.message = "Choose an ICC profile for your printer and paper (from the paper maker's website)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let profile = try PrintProfiles.importProfile(url) else {
                notice = "\"\(url.lastPathComponent)\" isn't an RGB printer profile, so it can't be used for printing."
                return
            }
            if !profiles.contains(profile) {
                profiles = (profiles + [profile]).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            settings.profilePath = profile.id
        } catch {
            notice = "Couldn't add the profile: \(error.localizedDescription)"
        }
    }

    /// Message for the print panel (shown under the colour settings).
    @Published var notice: String?

    // MARK: - Preview

    /// Shows `photo` on the page (nil clears the preview).
    func show(_ photo: Photo?) {
        guard photo?.id != self.photo?.id || photo?.develop != self.photo?.develop else { return }
        self.photo = photo
        if photo == nil {
            preview = nil
            layout = nil
            photoSize = nil
        }
        schedulePreview()
    }

    private func schedulePreview() {
        generation += 1
        let token = generation
        guard let photo else { return }
        isRendering = true
        let settings = settings
        let paper = paperSize
        let imageable = imageableArea
        let cached = sizeCache[photo.id].flatMap { $0.develop == photo.develop ? $0.size : nil }

        queue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard self?.isCurrent(token) ?? false else { return }
            guard let size = cached ?? PrintRenderer.developedSize(of: photo) else {
                DispatchQueue.main.async { self?.finish(token, photo: photo, size: nil, layout: nil, image: nil) }
                return
            }
            let layout = PrintPageLayout.make(paper: paper, imageable: imageable, photoSize: size, settings: settings)
            // Screen-sized render; print sharpening is for paper, not the screen.
            var previewSettings = settings
            previewSettings.sharpening = .off
            let longest = max(layout.image.width, layout.image.height)
            let scale = min(2, 1800 / max(longest, 1))
            let pixels = CGSize(width: (layout.image.width * scale).rounded(),
                                height: (layout.image.height * scale).rounded())
            let printImage = PrintRenderer.render(photo, pixels: pixels, layout: layout, settings: previewSettings)
            let proof = printImage.flatMap {
                settings.profilePath == nil ? $0 : PrintRenderer.proof($0, simulatePaper: settings.simulatePaper)
            }
            let white = settings.simulatePaper ? settings.profilePath.flatMap { PrintRenderer.paperWhite(profilePath: $0) } : nil
            DispatchQueue.main.async {
                self?.paperWhite = white
                self?.finish(token, photo: photo, size: size, layout: layout, image: proof)
            }
        }
    }

    /// Read on the preview queue; generation only changes on the main thread.
    private func isCurrent(_ token: Int) -> Bool {
        DispatchQueue.main.sync { token == generation }
    }

    private func finish(_ token: Int, photo: Photo, size: CGSize?, layout: PrintPageLayout?, image: CGImage?) {
        guard token == generation else { return }
        if let size { sizeCache[photo.id] = (photo.develop, size) }
        photoSize = size
        self.layout = layout
        preview = image
        isRendering = false
    }

    // MARK: - Print

    /// Prints one page per photo with the current settings (macOS print dialog first).
    @MainActor
    func print(_ photos: [Photo]) {
        guard !photos.isEmpty else { return }
        Self.prepare(printInfo)
        let view = PrintPageView(photos: photos, settings: settings)
        let operation = NSPrintOperation(view: view, printInfo: printInfo)
        operation.jobTitle = photos.count == 1 ? photos[0].fileName : "LumaGrader · \(photos.count) photos"
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.options.insert([.showsPaperSize, .showsOrientation, .showsCopies, .showsPageRange])
        _ = operation.run()
        // The print dialog may have changed the printer or paper.
        if let info = operation.printInfo.copy() as? NSPrintInfo {
            Self.prepare(info)
            printInfo = info
            rememberPrintInfo()
            schedulePreview()
        }
    }
}

/// The pages handed to the print system: one photo per page, rendered at print resolution
/// in the paper profile when the page is drawn.
final class PrintPageView: NSView {
    private let photos: [Photo]
    private let settings: PrintSettings
    private var pageSize = CGSize(width: 612, height: 792)
    private var rendered: (page: Int, image: CGImage, layout: PrintPageLayout)?

    init(photos: [Photo], settings: PrintSettings) {
        self.photos = photos
        self.settings = settings
        super.init(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        let info = NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared
        pageSize = info.paperSize
        setFrameSize(NSSize(width: pageSize.width, height: pageSize.height * CGFloat(photos.count)))
        range.pointee = NSRange(location: 1, length: photos.count)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(page - 1) * pageSize.height, width: pageSize.width, height: pageSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let operation = NSPrintOperation.current,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let page = operation.currentPage
        guard page >= 1, page <= photos.count, let result = render(page, info: operation.printInfo) else { return }
        let (image, layout) = result

        let rect = layout.image.offsetBy(dx: 0, dy: CGFloat(page - 1) * pageSize.height)
        context.saveGState()
        context.interpolationQuality = .high
        // The view is flipped; CGImage draws bottom-up.
        context.translateBy(x: 0, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()

        if settings.borderWidth > 0 {
            let width = CGFloat(settings.borderWidth)
            context.saveGState()
            context.setStrokeColor(CGColor(gray: settings.borderColor == .black ? 0 : 1, alpha: 1))
            context.setLineWidth(width)
            context.stroke(rect.insetBy(dx: width / 2, dy: width / 2))
            context.restoreGState()
        }
    }

    private func render(_ page: Int, info: NSPrintInfo) -> (CGImage, PrintPageLayout)? {
        if let rendered, rendered.page == page { return (rendered.image, rendered.layout) }
        let photo = photos[page - 1]
        guard let size = PrintRenderer.developedSize(of: photo) else { return nil }
        let layout = PrintPageLayout.make(paper: pageSize, imageable: PrintModel.topLeft(info),
                                          photoSize: size, settings: settings)
        guard let image = PrintRenderer.render(photo, pixels: layout.pixelSize(ppi: settings.resolution),
                                               layout: layout, settings: settings)
        else { return nil }
        rendered = (page, image, layout)
        return (image, layout)
    }
}
