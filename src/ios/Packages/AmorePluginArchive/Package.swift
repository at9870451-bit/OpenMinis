// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AmorePluginArchive",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "AmorePluginArchive", targets: ["AmorePluginArchive"])],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.19")],
    targets: [
        .target(name: "AmorePluginArchive", dependencies: ["ZIPFoundation"]),
        .testTarget(name: "AmorePluginArchiveTests", dependencies: ["AmorePluginArchive", "ZIPFoundation"], resources: [.copy("Fixtures")])
    ]
)
