// swift-tools-version: 6.0
import PackageDescription

// The Finder app is one native SwiftUI executable. SwiftTerm is linked as a
// SwiftPM product (no WebKit and no dynamically loaded JavaScript runtime).
// Pin a tagged version so CI and production use the same terminal emulator.
let package = Package(
    name: "KiriMobyNative",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "kiri-moby-ui", targets: ["KiriMobyUI"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.3")
    ],
    targets: [
        .executableTarget(
            name: "KiriMobyUI",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: ".",
            sources: ["MobyApp.swift"]
        )
    ]
)
