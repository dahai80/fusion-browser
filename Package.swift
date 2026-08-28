// swift-tools-version: 6.0
import PackageDescription

// Pure-Swift engine. E-17~20 (#68): Rust core removed — PRD §2 T1.4 evaluation
// concluded pure Swift (FBAXTreeReducer + JSONDecoder) covers Sanitizer+AXTree;
// the FFI boundary + FBCoreRustBuilder plugin + rust/ tree + useRustCore path
// were deleted. No plugin, no unsafeFlags, no absolute link paths.
let package = Package(
    name: "fusion-browser",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "fusion-browser", targets: ["FusionBrowser"]),
    ],
    targets: [
        .executableTarget(
            name: "FusionBrowser",
            path: "Sources/FusionBrowser"
        ),
        .testTarget(
            name: "FusionBrowserTests",
            dependencies: ["FusionBrowser"],
            path: "Tests/FusionBrowserTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
