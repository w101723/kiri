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
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")
    ],
    targets: [
        .executableTarget(
            name: "KiriMobyUI",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: ".",
            sources: ["KiriArcBoxContainerInfoTab.swift", "KiriArcBoxResourceView.swift", "ArcBoxContainerModel.swift", "ArcBoxAppColors.swift", "ArcBoxAppMetrics.swift", "ArcBoxLiquidGlass.swift", "ArcBoxDetailTabPicker.swift", "ArcBoxResourceListRowView.swift", "ArcBoxContainerListCells.swift", "ArcBoxInfoRow.swift", "ArcBoxInfoTableView.swift", "ArcBoxIconButton.swift", "ArcBoxStatusBadge.swift", "ArcBoxToolbarSeparator.swift", "KiriArcBoxContainersList.swift", "MobyApp.swift", "MobyRuntime.swift", "MobyUITheme.swift", "MobyUIModels.swift", "MobyModel.swift", "MobyTelemetry.swift", "MobyDockerEvents.swift", "MobyTerminal.swift", "MobyUIComponents.swift", "MobyContainerWorkspace.swift"]
        ),
        .testTarget(name: "KiriMobyUITests", dependencies: ["KiriMobyUI"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
