// swift-tools-version:5.9
// Open this file in Xcode (double-click), choose "My Mac", press ⌘R.
import PackageDescription

let package = Package(
    name: "Darkroom",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Darkroom",
            path: "Sources/Darkroom",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
