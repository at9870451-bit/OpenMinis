// swift-tools-version:5.10
// The native macOS shell of Poki Setup. The work happens in the Rust core, reached through the
// bundled `poki-setup-bridge` helper (JSON lines over a pipe); this package is only the UI.
import PackageDescription

let package = Package(
    name: "PokiSetup",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PokiSetup",
            path: "Sources/PokiSetup"
        ),
    ]
)
