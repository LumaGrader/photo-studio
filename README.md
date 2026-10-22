# LumaGrader Photo Studio

A free, open-source photo library and RAW editor for macOS. Import, cull, develop, export,
print and shoot tethered in one window. It works fully offline: no account, no cloud, and your
original photo files are never changed.

**Download:** <https://lumagrader.app> · **Support:** [Ko-fi](https://ko-fi.com/lumagrader)

Built for wedding, event, portrait and travel work. Part of the LumaGrader suite.

## Features

- **Library:** import from a card into dated shoot folders (rename, backup copy, preset on
  import), folders and collections, star ratings, flags and colour labels, Grid / Loupe /
  Compare / Survey, virtual copies, stacks of RAW + JPEG pairs, auto-rotate of portrait shots.
- **Culling:** AI Cull with the Mac's own on-device Vision models (closed eyes, sharpness,
  bursts of similar shots), Focus Check with focus peaking, People (face grouping).
- **Develop:** RAW decoding with Core Image, white balance, tone, tone curve, colour mixer,
  point colour, colour grading, detail and denoise, lens corrections and lens blur, crop and
  straighten, Auto Tone, Match Total Exposures, HDR merge.
- **Local edits:** masks (Select Subject, brush, linear, radial, luminance and colour range), healing.
- **Presets and profiles:** presets, `.cube` LUT profiles, Lightroom-style `.xmp` preset import,
  copy / paste / sync settings, Auto Sync.
- **Output:** export JPEG, 16-bit TIFF or PNG with resizing and watermarks; Print module with ICC
  paper profiles and soft proofing.
- **Client proofing:** a small offline website of selected photos for a client to heart and comment
  on; their list comes back with Import Client Picks (Purple label).
- **Tethered capture:** hot-folder tethering with Canon EOS Utility.
- **Catalog:** SQLite catalog with backups and restore.

## Requirements

- macOS 14 Sonoma or newer, Apple silicon or Intel.
- To build: Xcode 15 or newer (the full Xcode, not only the Command Line Tools, because SwiftUI
  macros need Xcode's toolchain).

## Install

Download the `.dmg` from <https://lumagrader.app> (or this repo's
[Releases](https://github.com/LumaGrader/photo-studio/releases)), open it and drag the
app into Applications.

The app is ad-hoc signed, not notarized, so macOS warns the first time you open it. Open it once,
click **Done**, then go to **System Settings › Privacy & Security** and click **Open Anyway**.
If macOS says the app is damaged:

```bash
xattr -dr com.apple.quarantine "/Applications/LumaGrader Photo Studio.app"
```

## Build from source

```bash
git clone https://github.com/LumaGrader/photo-studio.git
cd photo-studio
./scripts/make-app.sh            # dist/LumaGrader Photo Studio.app for this Mac's chip
./scripts/make-app.sh --install  # also copy it to /Applications and open it
./scripts/make-dmg.sh            # universal installer: dist/LumaGrader-Photo-Studio-<version>.dmg (+ .zip)
```

You can also open `Package.swift` in Xcode, choose **My Mac** and press ⌘R.
There are no third-party dependencies: only Apple frameworks (SwiftUI, AppKit, Core Image,
ImageIO, Vision) and the system SQLite.

## Project structure

```
Package.swift                 Swift package (target "Darkroom": the app's original working name)
Sources/Darkroom/
  DarkroomApp.swift           app entry, menus
  Catalog/                    SQLite catalog, migrations, backups
  Library/                    LibraryStore (state), import, scanning, AI Cull, faces, tether
  Develop/                    RAW rendering pipeline, masks, retouching, presets, LUTs
  Export/                     export queue, watermarks
  Print/                      Print module, ICC profiles, soft proof
  Models/                     develop settings, masks, photos
  Views/                      SwiftUI views, theme, in-app Guide
  Support/                    colour math, focus peaking
Resources/                    app icon, DMG background, Read Me for the installer
scripts/                      make-app.sh, make-dmg.sh
docs/CHANGELOG.md             version history and developer notes (Taglish)
```

Internal names keep the app's old working name on purpose so existing catalogs and settings
carry over: bundle id `com.rax.darkroom`, data in `~/Library/Application Support/Darkroom/`.

## Your data

- Catalog: `~/Library/Application Support/Darkroom/Catalog.sqlite` (ratings, labels, edits,
  collections, people). Back it up from **File › Catalog Backup**.
- Original photo files are only read, never modified. Delete Photo › Move to Trash is the only
  action that moves a file, and it asks first.

## Contributing

Questions: [support@lumagrader.app](mailto:support@lumagrader.app). Bug reports and ideas are welcome in [Issues](https://github.com/LumaGrader/photo-studio/issues).
Please include your macOS version, Mac model and camera / file type for RAW problems.

## License

Copyright © 2026 LumaGrader.

LumaGrader Photo Studio is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License version 3 as published by the Free Software Foundation.
It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the
implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See [LICENSE](LICENSE).

Not affiliated with Adobe, Apple or Canon. Lightroom is a trademark of Adobe.
