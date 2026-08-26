// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fusion-browser",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "fusion-browser", targets: ["FusionBrowser"]),
    ],
    targets: [
        .executableTarget(name: "FusionBrowser", path: "Sources/FusionBrowser"),
        .testTarget(
            name: "FusionBrowserTests",
            dependencies: ["FusionBrowser"],
            path: "Tests/FusionBrowserTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
