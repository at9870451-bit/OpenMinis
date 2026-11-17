// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PokiLoopback",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "PokiLoopback", targets: ["PokiLoopback"])],
    targets: [
        .target(name: "PokiLoopback"),
        .testTarget(name: "PokiLoopbackTests", dependencies: ["PokiLoopback"]),
    ]
)
