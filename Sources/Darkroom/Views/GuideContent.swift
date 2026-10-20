import Foundation

/// One feature in the LumaGrader Guide: what it does, how to use it, and its shortcuts.
struct GuideFeature: Identifiable, Hashable {
    let id: String
    let icon: String
    let title: String
    let section: String
    let summary: String
    let steps: [String]
    var shortcuts: [Shortcut] = []
    var tip: String? = nil

    struct Shortcut: Hashable {
        let keys: String
        let action: String
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let text = ([title, section, summary, tip ?? ""] + steps + shortcuts.map { $0.action }).joined(separator: " ")
        return text.lowercased().contains(q)
    }
}

/// The tutorial content of the Features tab, in the order it's shown.
enum GuideContent {
    static let sections = ["Get Started", "Library", "Develop", "Output", "Workflow"]

    static let features: [GuideFeature] = [
        // MARK: Get Started
        GuideFeature(
            id: "import", icon: "sdcard", title: "Import from a Card", section: "Get Started",
            summary: "Copy photos from your camera card into a dated shoot folder, renamed and backed up.",
            steps: [
                "Insert the card, then choose File ▸ Import Photos… (or Import… at the bottom left).",
                "Pick the main folder and type a shoot name, e.g. \"Santos Wedding\". Photos go to Main folder ▸ Year ▸ Date + Shoot name.",
                "Choose renaming (Date_Shoot_0001), a backup copy on another drive, a preset and your Creator / Copyright.",
                "Click Import. Photos already imported before are skipped. Eject the card when it's done.",
            ],
            shortcuts: [.init(keys: "⇧⌘I", action: "Import Photos")],
            tip: "Already have photos on a drive? Use File ▸ Add Folder Without Copying… — the files stay where they are."),
        GuideFeature(
            id: "basics", icon: "rectangle.3.group", title: "The Workspace", section: "Get Started",
            summary: "Library to organise, Develop to edit, Print to print. Switch at the top right.",
            steps: [
                "Left panel: folders, collections, people, presets and history.",
                "Centre: Grid (G), Loupe (E), Compare (C), Survey (N) or the Develop view (D).",
                "Right panel: histogram and metadata in Library, the edit panels in Develop.",
                "Bottom: the filmstrip. Tab hides the side panels, ⇧Tab hides everything, F is full screen.",
            ],
            shortcuts: [.init(keys: "G / E / C / N / D", action: "Grid / Loupe / Compare / Survey / Develop"),
                        .init(keys: "⌘K", action: "Command Palette: type any command")],
            tip: "Can't find something? Press ⌘K and type what you want, e.g. \"exposure\", \"export\" or \"tether\"."),

        // MARK: Library
        GuideFeature(
            id: "rate", icon: "star", title: "Rate, Flag and Label", section: "Library",
            summary: "Mark your best shots quickly, then filter to see only those.",
            steps: [
                "Press 1–5 for stars (0 clears), P to pick, X to reject, U to unflag.",
                "Press 6 Red, 7 Yellow, 8 Green, 9 Blue for colour labels (Purple in the right-click menu).",
                "With several photos selected (⌘-click / ⇧-click), it applies to all of them.",
                "Use the Library Filter bar above the grid to show only Picks, 3+ stars, a label or a person.",
                "Right-click any photo (grid, filmstrip or the big preview) for more, including Delete Photo… (⌫): Move to Trash, or Remove from Catalog to keep the file.",
            ],
            shortcuts: [.init(keys: "1–5 · P · X · U", action: "Stars · Pick · Reject · Unflag"),
                        .init(keys: "6 · 7 · 8 · 9", action: "Red · Yellow · Green · Blue label")]),
        GuideFeature(
            id: "autorotate", icon: "rotate.right", title: "Auto-Rotate Portraits", section: "Library",
            summary: "Vertical shots saved sideways (camera auto-rotate off) are turned upright for you.",
            steps: [
                "It's on by default: after Import, Add Folder, Synchronize Folder and each tethered shot, LumaGrader checks photos the camera didn't rotate.",
                "It looks for upright faces and people, so it works for weddings, events and portraits. Photos without people are left as they are.",
                "Turn a photo yourself with Rotate Left / Right (⌘[ ⌘]); that also undoes an automatic turn. Your files are never changed.",
                "Photo ▸ Auto-Rotate Portraits checks the selected photos again; Photo ▸ Auto-Rotate Portraits on Import turns the automatic check off.",
            ],
            shortcuts: [.init(keys: "⌘[ / ⌘]", action: "Rotate Left / Right")]),
        GuideFeature(
            id: "survey", icon: "square.grid.2x2", title: "Compare and Survey", section: "Library",
            summary: "Pick the best of a burst by looking at the shots side by side.",
            steps: [
                "Select 2 or more photos, then press N for Survey: they all show side by side.",
                "Click one to make it active; P, X and 1–5 apply to the active photo only. ✕ removes a photo from the survey.",
                "Compare (C) shows two photos: the Select on the left, the Candidate on the right. ← → changes the candidate.",
            ],
            shortcuts: [.init(keys: "N", action: "Survey"), .init(keys: "C", action: "Compare")]),
        GuideFeature(
            id: "focus", icon: "scope", title: "Focus Check", section: "Library",
            summary: "See which parts are sharp before you pick — great for wildlife and the bride's eyes.",
            steps: [
                "Press ⇧F (or the ⊙ button in the toolbar) in Loupe, Compare or Survey. In-focus edges turn red.",
                "Press ⇧Z (or the viewfinder button) to jump to 100% on the sharpest area of the photo.",
                "Change the sensitivity in Photo ▸ Focus Peaking Sensitivity. Zoomed in, the check uses the full-size file.",
            ],
            shortcuts: [.init(keys: "⇧F", action: "Focus peaking on/off"), .init(keys: "⇧Z", action: "Zoom to sharpest area")]),
        GuideFeature(
            id: "cull", icon: "sparkles", title: "AI Cull", section: "Library",
            summary: "Let your Mac check sharpness, closed eyes and similar shots, then pick the best of each run.",
            steps: [
                "Open a folder in Grid, then click AI Cull… in the filter bar above the photos (or ⌘K ▸ AI Cull…).",
                "Run the analysis. Everything happens on your Mac; nothing is uploaded.",
                "Choose what to flag: best of each run, blurry shots, closed eyes. Change any flag by hand afterwards.",
            ]),
        GuideFeature(
            id: "people", icon: "person.2", title: "People (Faces)", section: "Library",
            summary: "Find faces and name them, then show every photo of a person.",
            steps: [
                "Choose Photo ▸ Find Faces. Your Mac looks for faces in the photos of the current folder.",
                "Open Photo ▸ People…: similar faces are grouped. Type a name and click Name, or Yes when it guesses right.",
                "Click a person in the left panel (or the Person filter) to see only their photos.",
            ],
            tip: "Face grouping is approximate — check each group before naming it."),
        GuideFeature(
            id: "collections", icon: "folder.badge.plus", title: "Collections and Virtual Copies", section: "Library",
            summary: "Group photos from different folders, and try several edits of one photo.",
            steps: [
                "Right-click photos ▸ Add to Collection, or + in the Collections panel ▸ New Collection from Selection.",
                "Photo ▸ Create Virtual Copy (⌘') makes a second version with its own edits; the file isn't copied.",
            ],
            shortcuts: [.init(keys: "⌘'", action: "Create Virtual Copy")]),

        // MARK: Develop
        GuideFeature(
            id: "basic", icon: "slider.horizontal.3", title: "Basic Editing and Auto", section: "Develop",
            summary: "White balance, exposure, contrast, highlights, shadows and colour, like Lightroom.",
            steps: [
                "Press D to open the photo in Develop. Drag a slider, or click its number to type a value. Double-click a slider to reset it.",
                "Auto (in Basic ▸ Tone) sets the tone sliders for you. Click Auto again to undo it — it turns blue while it's on.",
                "W picks white balance from a neutral spot. \\ shows before / after, J shows clipped highlights and shadows.",
                "⌘Z / ⇧⌘Z undo and redo; the History panel on the left lists every step.",
            ],
            shortcuts: [.init(keys: "⌘U", action: "Auto Tone (again = undo)"), .init(keys: "W", action: "White balance picker"),
                        .init(keys: "\\", action: "Before / after"), .init(keys: "J", action: "Show clipping")]),
        GuideFeature(
            id: "masking", icon: "circle.dashed.inset.filled", title: "Masking", section: "Develop",
            summary: "Edit just part of the photo: the subject, the sky, a brushed area or a gradient.",
            steps: [
                "Press ⇧W or click the masking button, then choose Subject, Background, Brush (K), Linear (M), Radial (⇧M), Luminance or Color Range.",
                "Adjust the sliders of the mask. O shows the red overlay of what's selected.",
                "Add or subtract more areas to the same mask. Click another Develop section when you're done — Masking closes by itself.",
            ],
            shortcuts: [.init(keys: "⇧W", action: "Masking"), .init(keys: "K / M / ⇧M", action: "Brush / Linear / Radial"),
                        .init(keys: "O", action: "Mask overlay")]),
        GuideFeature(
            id: "retouch", icon: "bandage", title: "Healing, Denoise and Lens Blur", section: "Develop",
            summary: "Remove spots, clean high-ISO noise and blur the background.",
            steps: [
                "Healing (Q): click a spot or blemish; LumaGrader picks a matching area. Drag the circle or its source; [ ] changes the size.",
                "Denoise (Detail panel): raise Amount for high-ISO shots and check at 100% (Z).",
                "Lens Blur: blurs the background around the subject, with bokeh shape and highlight boost.",
            ],
            shortcuts: [.init(keys: "Q", action: "Healing"), .init(keys: "[ ]", action: "Spot size"), .init(keys: "Z", action: "Zoom")]),
        GuideFeature(
            id: "sync", icon: "arrow.triangle.2.circlepath", title: "Presets, Copy and Sync", section: "Develop",
            summary: "Edit one photo and give the same look to many.",
            steps: [
                "Copy… / Paste (bottom left in Develop) copies chosen settings to other photos. ⇧⌘V pastes, ⌥⌘V pastes from the previous photo.",
                "Select several photos and click Sync… to copy the active photo's settings to all of them.",
                "Turn on Auto (next to Sync) to edit all selected photos at the same time.",
                "Save Settings as Preset… keeps a look for later; Import Presets… reads Lightroom presets.",
            ],
            shortcuts: [.init(keys: "⇧⌘S", action: "Sync Settings"), .init(keys: "⌥⇧⌘A", action: "Auto Sync"),
                        .init(keys: "⌥⌘C", action: "Copy all settings")]),
        GuideFeature(
            id: "hdr", icon: "square.stack.3d.up", title: "HDR Merge", section: "Develop",
            summary: "Combine bracketed exposures into one photo with full highlight and shadow detail.",
            steps: [
                "Select 2–9 bracketed shots of the same scene.",
                "Choose Photo ▸ Photo Merge ▸ HDR… (⌃H). Keep Auto Align on for handheld shots; raise Deghost if things moved.",
                "The merged 16-bit TIFF is added next to the originals and selected for editing.",
            ],
            shortcuts: [.init(keys: "⌃H", action: "HDR Merge")]),

        // MARK: Output
        GuideFeature(
            id: "export", icon: "square.and.arrow.up", title: "Export", section: "Output",
            summary: "Save edited JPEGs or TIFFs for clients, social media or print labs.",
            steps: [
                "Select photos and press ⇧⌘E (or Export at the bottom left).",
                "Choose size, format, quality, file names and a watermark, or tick several export presets at once.",
                "Exports run in the background; progress shows at the top. Export with Previous (⌥⇧⌘E) repeats the last export.",
            ],
            shortcuts: [.init(keys: "⇧⌘E", action: "Export"), .init(keys: "⌥⇧⌘E", action: "Export with Previous")]),
        GuideFeature(
            id: "print", icon: "printer", title: "Print", section: "Output",
            summary: "Print with your paper's ICC profile and preview how it will look on paper.",
            steps: [
                "Click Print at the top right (⌥⌘P). Use Page Setup… (⇧⌘P) for paper size and orientation.",
                "Set margins, Fit or Fill, resolution and print sharpening for matte or glossy paper.",
                "In Color Management, choose your paper profile (Add Profile… installs one you downloaded). Simulate Paper & Ink previews the paper white.",
                "Press ⌘P. In the print dialog, turn the printer's own colour management Off and choose the same paper type.",
            ],
            shortcuts: [.init(keys: "⌘P", action: "Print"), .init(keys: "⇧⌘P", action: "Page Setup")],
            tip: "If prints come out darker than the screen, turn on Print Adjustment and raise Brightness a little."),

        // MARK: Workflow
        GuideFeature(
            id: "tether", icon: "cable.connector", title: "Tethered Capture", section: "Workflow",
            summary: "Shoot with the camera connected; each photo appears in LumaGrader right away.",
            steps: [
                "Install Canon EOS Utility (free from Canon). Connect the camera with a USB-C data cable and turn it on.",
                "Choose File ▸ Tethered Capture ▸ Start… Type a session name, click Copy Path, then Start.",
                "In EOS Utility: Preferences ▸ Destination Folder = the copied path. Open Remote Shooting and shoot.",
                "In the tether bar, Develop applies None, Same as Previous or a preset to each new shot.",
            ],
            tip: "EOS Utility says the camera is busy? Quit Image Capture and EOS Webcam Utility, then turn the camera off and on."),
        GuideFeature(
            id: "backup", icon: "externaldrive.badge.timemachine", title: "Catalog Backup", section: "Workflow",
            summary: "Keep a copy of your ratings, edits and collections in case something goes wrong.",
            steps: [
                "File ▸ Catalog Backup ▸ Back Up Now makes a checked copy of the catalog.",
                "Turn on Back Up Daily, and Choose Backup Folder… on another drive for the safest setup.",
                "Restore from Backup… reopens LumaGrader with an earlier copy; the current one is kept so you can switch back.",
            ],
            tip: "The catalog holds your edits; your photo files themselves are never changed by LumaGrader."),
    ]
}
